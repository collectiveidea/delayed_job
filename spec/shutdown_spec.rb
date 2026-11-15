require 'helper'

describe 'Stopping a worker' do
  let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.05) }
  let(:log) { Concurrent::Array.new }

  before do
    Delayed::Job.delete_all
    GateJob.reset
    capture_say(log, *and_workers(dispatcher))
  end

  after do
    GateJob.release = true
    Delayed::Worker.reset
  end

  def enqueue(*jobs)
    jobs.map { |job| Delayed::Job.enqueue(job) }
  end

  # Runs the dispatcher on a thread until `count` jobs have started.
  def run_until_started(count)
    thread = Thread.new { dispatcher.run }
    Timeout.timeout(5) { count.times { GateJob.started.pop } }
    thread
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  describe Delayed::ShutdownInterrupt do
    it 'is not a StandardError, so `rescue => e` in jobs does not catch it' do
      expect(described_class.ancestors).not_to include StandardError
      expect(described_class.ancestors).to include Exception
    end
  end

  describe 'Worker#run' do
    it 're-raises the interrupt instead of recording a failed attempt' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      allow(job).to receive(:invoke_job).and_raise(Delayed::ShutdownInterrupt)
      worker = Delayed::Worker.new
      expect(worker).not_to receive(:fail_attempt)
      expect { worker.run(job) }.to raise_error(Delayed::ShutdownInterrupt)
      expect(job.attempts).to eq 0
    end
  end

  context 'without a shutdown timeout (the default)' do
    it 'waits for running jobs to finish' do
      job, = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      sleep 0.5
      expect(thread).to be_alive
      GateJob.release = true
      Timeout.timeout(5) { thread.join }

      expect(GateJob.finished).to eq [:a]
      expect(GateJob.interrupted).to be_empty
      expect(Delayed::Job.all).not_to include(job)
    end
  end

  context 'with a shutdown timeout' do
    before { Delayed::Worker.shutdown_timeout = 0.3 }

    it 'lets jobs that finish in time complete' do
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      GateJob.release = true
      Timeout.timeout(5) { thread.join }
      expect(GateJob.finished).to eq [:a]
      expect(GateJob.interrupted).to be_empty
    end

    it 'interrupts jobs still running after it, and releases them for another worker' do
      jobs = enqueue(GateJob.new(:a), GateJob.new(:b))
      run_at = jobs.map(&:run_at)
      thread = run_until_started(2)
      took = elapsed do
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
      end

      expect(took).to be_between(0.25, 2)
      expect(GateJob.interrupted).to contain_exactly(:a, :b)
      expect(GateJob.finished).to be_empty
      expect(Delayed::Job.all).to match_array(jobs)
      expect(jobs.map(&:locked_by)).to eq [nil, nil]
      expect(jobs.map(&:locked_at)).to eq [nil, nil]
      expect(jobs.map(&:attempts)).to eq [0, 0]
      expect(jobs.map(&:run_at)).to eq run_at
      expect(jobs.map(&:last_error)).to eq [nil, nil]
      expect(log).to include(['warn', 'Shutdown timeout of 0.3s exceeded: interrupting 2 running job(s)'])
      expect(log.map(&:last).grep(/interrupted by shutdown; released for another worker/).size).to eq 2
    end

    it 'does not run :error callbacks or count the interruption as a failure' do
      enqueue(GateJob.new(:a))
      errors = []
      dispatcher # Worker.new resets the lifecycle
      Delayed::Worker.lifecycle.before(:error) { |_w, job| errors << job }
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(errors).to be_empty
    end

    it 'counts the timeout from when the stop was requested' do
      Delayed::Worker.shutdown_timeout = 1
      enqueue(GateJob.new(:a))
      in_slow_poll = Queue.new
      calls = 0
      allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, *args|
        next m.call(*args) if (calls += 1) == 1
        in_slow_poll << true
        sleep 1.5 # The dispatcher only notices the stop after this.
        []
      end
      thread = run_until_started(1)
      Timeout.timeout(5) { in_slow_poll.pop }
      took = elapsed do
        dispatcher.stop
        Timeout.timeout(10) { thread.join }
      end
      # The 1s timeout ran out during the 1.5s poll: the job is interrupted
      # as soon as the dispatcher looks (about 1.5s), not 1s after that (2.5s).
      expect(took).to be < 2.3
      expect(GateJob.interrupted).to eq [:a]
    end

    it 'treats 0 as "interrupt at once"' do
      Delayed::Worker.shutdown_timeout = 0
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      took = elapsed do
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
      end
      expect(took).to be < 1 # At once, not after the job (which never ends by itself).
      expect(GateJob.interrupted).to eq [:a]
    end

    context 'when a job does not stop when interrupted' do
      before { stub_const('Delayed::Dispatcher::INTERRUPT_GRACE', 0.3) }

      it 'gives up on it after INTERRUPT_GRACE seconds and leaves it locked' do
        job, = enqueue(GateJob.new(:stubborn, true))
        thread = run_until_started(1)
        took = elapsed do
          dispatcher.stop
          Timeout.timeout(5) { thread.join }
        end

        expect(took).to be_between(0.5, 2)
        expect(job.locked_by).not_to be_nil
        expect(log).to include(['error', '1 job(s) did not stop within 0.3s of being interrupted; ' \
                                         'leaving them locked until max_run_time expires'])
      ensure
        GateJob.release = true
        dispatcher.instance_variable_get(:@threads).each { |t| t.join(5) }
      end
    end

    it 'logs and carries on when releasing a job fails' do
      enqueue(GateJob.new(:a))
      allow(Delayed::Job).to receive(:clear_locks!).and_raise(IOError, 'db down')
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(log.select { |level, _| level == 'error' }.map(&:last)).
        to include(/\ACould not release the jobs of .+ thread:\d: IOError: db down\z/)
    end
  end

  describe 'interrupts arriving outside of a job' do
    let(:reported) { Concurrent::Array.new }

    before do
      NapJob.outcomes = Queue.new
      SimpleJob.runs = 0
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
    end

    def worker_threads
      dispatcher.instance_variable_get(:@threads)
    end

    def start
      @thread = Thread.new { dispatcher.run }
      wait_until(5) { worker_threads.size == 2 && worker_threads.all? { |t| t.status == 'sleep' } }
      @thread
    end

    def stop_and_join
      dispatcher.stop
      Timeout.timeout(5) { @thread.join }
    end

    after { stop_and_join if @thread && @thread.alive? }

    [Delayed::ShutdownInterrupt.new('late'), SignalException.new('TERM')].each do |interrupt|
      it "ignores a #{interrupt.class} raised into an idle worker thread" do
        start
        worker_threads.each { |t| t.raise(interrupt.class, interrupt.message) }
        sleep 0.1
        expect(worker_threads).to all(be_alive)

        job = Delayed::Job.enqueue(SimpleJob.new)
        wait_until(5) { !Delayed::Job.all.include?(job) }
        stop_and_join
        expect(reported).to be_empty
        expect(dispatcher.instance_variable_get(:@thread_error)).to be_nil
      end

      it "does not carry a #{interrupt.class} that arrived between jobs into the next job" do
        start
        worker_threads.each { |t| t.raise(interrupt.class, interrupt.message) }
        sleep 0.05
        jobs = Array.new(2) { Delayed::Job.enqueue(NapJob.new) }
        outcomes = Timeout.timeout(5) { Array.new(2) { NapJob.outcomes.pop } }
        expect(outcomes).to eq [:finished, :finished]
        wait_until(5) { (Delayed::Job.all & jobs).empty? }
        expect(reported).to be_empty
      end
    end

    it 'does not interrupt a thread recording the job it just finished' do
      dispatcher.workers.each { |w| allow(w).to receive(:say) }
      recording = Queue.new
      gate = Queue.new
      allow(dispatcher).to receive(:job_finished).and_wrap_original do |m, *args|
        recording << Thread.current
        gate.pop
        m.call(*args)
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      start
      thread = Timeout.timeout(5) { recording.pop }
      thread.raise(Delayed::ShutdownInterrupt, 'late')
      sleep 0.05
      gate << true
      wait_until(5) { dispatcher.send(:in_flight).zero? }

      expect(thread).to be_alive
      expect(Delayed::Job.all).not_to include(job)
      expect(SimpleJob.runs).to eq 1
      expect(dispatcher.send(:snapshot).first).to match_array dispatcher.workers # Both idle again.
      allow(dispatcher).to receive(:job_finished).and_call_original
      stop_and_join
      expect(reported).to be_empty
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
    end

    it 'lets the :execute callbacks (e.g. ClearLocks) finish when interrupted' do
      dispatcher # Worker.new resets the lifecycle.
      exiting = Queue.new
      gate = Queue.new
      cleared = Queue.new
      Delayed::Worker.lifecycle.after(:execute) do |worker|
        exiting << Thread.current
        gate.pop
        cleared << worker.name
      end
      start
      dispatcher.stop
      threads = Timeout.timeout(5) { Array.new(2) { exiting.pop } }
      threads.each { |t| t.raise(Delayed::ShutdownInterrupt, 'late') }
      sleep 0.05
      2.times { gate << true }
      Timeout.timeout(5) { @thread.join }

      expect(Array.new(cleared.size) { cleared.pop }).to match_array dispatcher.workers.map(&:name)
      expect(reported).to be_empty
      expect(dispatcher.instance_variable_get(:@thread_error)).to be_nil
    end

    it 'still interrupts a running job, and lets the thread release it' do
      Delayed::Worker.shutdown_timeout = 0
      job, = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(GateJob.interrupted).to eq [:a]
      expect(job.reload.locked_by).to be_nil
      expect(reported).to be_empty
    end

    it 'releases a job a signal was raised into, attempts unchanged, and carries on' do
      dispatcher.workers.each { |w| allow(w).to receive(:say) }
      job, = enqueue(GateJob.new(:a))
      run_at = job.run_at
      thread = run_until_started(1)
      busy = dispatcher.instance_variable_get(:@running).keys.first
      busy.raise(SignalException, 'TERM')
      wait_until(5) { GateJob.interrupted == [:a] }
      wait_until(5) { !(job.locked_by && GateJob.started.empty?) }
      # Not failed: the same job, unlocked as it was (or picked up again).
      expect([job.attempts, job.run_at, job.last_error, job.failed_at]).to eq [0, run_at, nil, nil]
      expect(busy).to be_alive # The thread carries on.
      GateJob.release = true
      wait_until(5) { Delayed::Job.count.zero? }
      # The job is deleted before its thread frees the slot.
      wait_until(5) { dispatcher.send(:in_flight).zero? }
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
    end

    it 'still interrupts a running job with a signal (Worker.raise_signal_exceptions)' do
      dispatcher.workers.each { |w| allow(w).to receive(:say) }
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      busy = dispatcher.instance_variable_get(:@running).keys.first
      busy.raise(SignalException, 'TERM')
      wait_until(5) { GateJob.interrupted == [:a] }
      GateJob.release = true # Released, it is run again.
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
    end
  end

  describe 'on a Ruby without interrupt masking' do
    # Makes the dispatcher take its paths for a Ruby without interrupt
    # masking. Thread.handle_interrupt itself stays: the timeout gem (and
    # with it every job's max_run_time) needs it.
    def hide_interrupt_masking
      allow(Delayed::Dispatcher).to receive(:interrupt_masking?).and_return(false)
    end

    # Whether the method was called by Delayed Job's own code: its direct
    # caller, past rspec-mocks. Not merely with Delayed Job on the stack:
    # the timeout gem (called by Worker#run) calls Thread.handle_interrupt
    # itself, when it starts its thread on the first Timeout.timeout.
    def called_by_delayed_job?(stack)
      origin = stack.find { |line| !line.include?('/rspec-mocks') && !line.include?(__FILE__) }
      origin.to_s.include?('lib/delayed/')
    end

    # The dispatcher's own calls to the masking methods, which must not
    # happen without masking.
    def forbid_masking_calls
      allow(Thread).to receive(:handle_interrupt).and_wrap_original do |m, *args, &block|
        raise 'Thread.handle_interrupt called by the dispatcher' if called_by_delayed_job?(caller)
        m.call(*args, &block)
      end
      allow(Thread).to receive(:pending_interrupt?).and_wrap_original do |m, *args|
        raise 'Thread.pending_interrupt? called by the dispatcher' if called_by_delayed_job?(caller)
        m.call(*args)
      end
    end

    before { SimpleJob.runs = 0 }

    it 'is detected' do
      expect(Delayed::Dispatcher.interrupt_masking?).to be true
      allow(Thread).to receive(:respond_to?).and_call_original
      allow(Thread).to receive(:respond_to?).with(:handle_interrupt).and_return(false)
      expect(Delayed::Dispatcher.interrupt_masking?).to be false
    end

    it 'is not needed by .interruptible and .deferring_interrupts, which just run the block' do
      hide_interrupt_masking
      forbid_masking_calls
      expect(Delayed::Dispatcher.interruptible { :ran }).to eq :ran
      expect(Delayed::Dispatcher.deferring_interrupts { :ran }).to eq :ran
    end

    it 'finds no stale interrupts' do
      hide_interrupt_masking
      forbid_masking_calls
      expect(dispatcher.send(:stale_interrupt_pending?)).to be false
      expect { dispatcher.send(:discard_stale_interrupts) }.not_to raise_error
    end

    it 'still runs jobs on worker threads' do
      hide_interrupt_masking
      forbid_masking_calls
      jobs = Array.new(3) { Delayed::Job.enqueue(SimpleJob.new) }
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(SimpleJob.runs).to eq 3
      expect(Delayed::Job.all & jobs).to be_empty
    end

    it 'still interrupts and releases running jobs on quit' do
      hide_interrupt_masking
      forbid_masking_calls
      job, = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [:a]
      job.reload
      expect([job.locked_by, job.attempts]).to eq [nil, 0]
    end

    it 'still runs jobs inline with Worker#work_off' do
      hide_interrupt_masking
      forbid_masking_calls
      Delayed::Job.enqueue(SimpleJob.new)
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      expect(worker.work_off).to eq [1, 0]
    end
  end

  describe '#discard_stale_interrupts' do
    let(:defer) { Delayed::Dispatcher::DEFER_SHUTDOWN_INTERRUPTS }

    # Runs the block on a thread that defers shutdown interrupts, as worker
    # threads do, after raising `interrupts` into it.
    def on_deferring_thread(*interrupts)
      ready = Queue.new
      go = Queue.new
      thread = Thread.new do
        Thread.handle_interrupt(defer) do
          ready << true
          go.pop
          yield
        end
      end
      Timeout.timeout(5) { ready.pop }
      interrupts.each { |klass, message| thread.raise(klass, message) }
      sleep 0.05
      go << true
      Timeout.timeout(5) { thread.value }
    end

    it 'drops a pending ShutdownInterrupt' do
      result = on_deferring_thread([Delayed::ShutdownInterrupt, 'stale']) do
        dispatcher.send(:discard_stale_interrupts)
        Thread.pending_interrupt?
      end
      expect(result).to be false
    end

    it 'drops a pending signal' do
      result = on_deferring_thread([SignalException, 'TERM']) do
        dispatcher.send(:discard_stale_interrupts)
        Thread.pending_interrupt?
      end
      expect(result).to be false
    end

    it 'drops several pending interrupts' do
      result = on_deferring_thread([Delayed::ShutdownInterrupt, 'one'], [SignalException, 'TERM'],
                                   [Delayed::ShutdownInterrupt, 'two']) do
        dispatcher.send(:discard_stale_interrupts)
        Thread.pending_interrupt?
      end
      expect(result).to be false
    end

    it 'returns at once when nothing is pending' do
      allow(dispatcher).to receive(:stale_interrupt_pending?).and_call_original
      expect(Thread).not_to receive(:pass)
      on_deferring_thread { dispatcher.send(:discard_stale_interrupts) }
      expect(dispatcher).to have_received(:stale_interrupt_pending?).once
    end

    it 'leaves other deferred interrupts pending' do
      skip "TruffleRuby's Thread.pending_interrupt? takes no class" unless Delayed::Dispatcher.pending_interrupt_by_class?
      ready = Queue.new
      go = Queue.new
      thread = Thread.new do
        Thread.handle_interrupt(defer.merge(IOError => :never)) do
          ready << true
          go.pop
          dispatcher.send(:discard_stale_interrupts)
          [Thread.pending_interrupt?(Delayed::ShutdownInterrupt), Thread.pending_interrupt?(IOError)]
        end
      end
      thread.report_on_exception = false
      Timeout.timeout(5) { ready.pop }
      thread.raise(Delayed::ShutdownInterrupt, 'stale')
      thread.raise(IOError, 'other')
      sleep 0.05
      go << true
      # The IOError is delivered once the block (and its mask) exits.
      expect { Timeout.timeout(5) { thread.value } }.to raise_error(IOError, 'other')
    end

    it 'gives up instead of spinning when a pending interrupt is never delivered' do
      allow(dispatcher).to receive(:stale_interrupt_pending?).and_return(true) # Stuck pending.
      passes = 0
      allow(Thread).to receive(:pass) { passes += 1 }
      expect { Timeout.timeout(2) { dispatcher.send(:discard_stale_interrupts) } }.not_to raise_error
      expect(passes).to eq 1
    end
  end

  describe 'interrupts arriving after the job ran' do
    let(:reported) { Concurrent::Array.new }
    let(:paused) { Queue.new }

    before do
      SimpleJob.runs = 0
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
    end

    # Quits while the worker thread is paused at `stage` (after the job's
    # own code ran), then lets it go on.
    def quit_while_paused
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { paused.pop }
      dispatcher.quit
      sleep 0.1 # The interrupt is raised into the paused thread meanwhile.
      yield if block_given?
      Timeout.timeout(10) { thread.join }
    end

    def pause_in(klass, method)
      p = paused
      allow_any_instance_of(klass).to receive(method).and_wrap_original do |m, *args, &block|
        p << true
        sleep 0.3
        m.call(*args, &block)
      end
    end

    it 'does not release (to run again) a job interrupted while it is being finished' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      pause_in(Delayed::Backend::Test::Job, :destroy)
      quit_while_paused
      expect(SimpleJob.runs).to eq 1
      expect(Delayed::Job.all).not_to include(job)
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
      expect(reported).to be_empty
    end

    it 'does not release a job interrupted while it is being rescheduled after failing' do
      job = Delayed::Job.enqueue(ErrorJob.new)
      pause_in(Delayed::Backend::Test::Job, :save!)
      quit_while_paused
      job.reload
      expect(job.attempts).to eq 1
      expect(job.last_error).to match(/did not work/)
      expect(job.locked_by).to be_nil
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
    end

    it 'lets :perform callbacks after the job run uninterrupted' do
      dispatcher # Worker.new resets the lifecycle.
      after_perform = []
      p = paused
      Delayed::Worker.lifecycle.after(:perform) do |_worker, job|
        p << true
        sleep 0.3
        after_perform << job.id
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      quit_while_paused
      expect(after_perform).to eq [job.id]
      expect(Delayed::Job.all).not_to include(job)
    end

    it 'lets perform subscribers run uninterrupted' do
      seen = []
      p = paused
      subscribe(:job_performed) do |*args|
        p << true
        sleep 0.3
        seen << args.last[:success]
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      quit_while_paused
      expect(seen).to eq [true]
      expect(Delayed::Job.all).not_to include(job)
    end

    %i(success after).each do |hook|
      it "lets the job's #{hook} hook run uninterrupted (the job is not run again)" do
        p = paused
        allow_any_instance_of(SimpleJob).to receive(hook) do
          p << true
          sleep 0.3
        end
        job = Delayed::Job.enqueue(SimpleJob.new)
        quit_while_paused
        expect(SimpleJob.runs).to eq 1
        expect(Delayed::Job.all).not_to include(job)
        expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
        expect(reported).to be_empty
      end
    end

    it "lets a job's slow success hook finish after a shutdown timeout passes" do
      Delayed::Worker.shutdown_timeout = 0
      SlowHookJob.reset
      job = Delayed::Job.enqueue(SlowHookJob.new)
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { SlowHookJob.in_hook.pop }
      dispatcher.stop # The deadline passes at once: running jobs are interrupted.
      Thread.new do
        sleep 0.3
        SlowHookJob.release = true
      end
      Timeout.timeout(10) { thread.join }
      expect(SlowHookJob.performed.size).to eq 1
      expect(Delayed::Job.all).not_to include(job)
      expect(reported).to be_empty
    end

    it 'still interrupts the job itself' do
      job, = enqueue(GateJob.new(:a))
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { GateJob.started.pop }
      dispatcher.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [:a]
      expect(job.reload.locked_by).to be_nil
      expect(job.attempts).to eq 0
    end

    it 'still times jobs out' do
      job = Delayed::Job.enqueue(LongRunningJob.new)
      allow_any_instance_of(LongRunningJob).to receive(:max_run_time).and_return(1)
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      expect(worker.work_off(1)).to eq [0, 1]
      expect(job.reload.last_error).to match(/execution expired/)
    end
  end

  describe 'jobs handed to a thread that has not started them by the shutdown deadline' do
    let(:reported) { Concurrent::Array.new }
    let(:dispatcher) { Delayed::Dispatcher.new(:threads => 1, :sleep_delay => 0.05) }

    before do
      SimpleJob.runs = 0
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
    end

    # Holds the worker thread after it took a job off its inbox, before it
    # starts it, until the gate opens.
    def hold_before_start
      held = Queue.new
      gate = Queue.new
      allow(dispatcher).to receive(:discard_stale_interrupts) do
        held << true
        gate.pop
      end
      [held, gate]
    end

    def run_and_hold
      held, gate = hold_before_start
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { held.pop }
      [thread, gate]
    end

    it 'are released unstarted on quit, attempts unchanged' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      thread, gate = run_and_hold
      dispatcher.quit
      sleep 0.1
      gate << true
      Timeout.timeout(10) { thread.join }

      expect(SimpleJob.runs).to eq 0
      job.reload
      expect([job.locked_by, job.locked_at, job.attempts]).to eq [nil, nil, 0]
      expect(log.map(&:last).grep(/not started before shutdown; released for another worker/).size).to eq 1
      expect(reported).to be_empty
    end

    it 'are released unstarted once the shutdown timeout passed' do
      Delayed::Worker.shutdown_timeout = 0.1
      job = Delayed::Job.enqueue(SimpleJob.new)
      thread, gate = run_and_hold
      dispatcher.stop
      sleep 0.3 # Past the timeout.
      gate << true
      Timeout.timeout(10) { thread.join }

      expect(SimpleJob.runs).to eq 0
      expect(job.reload.locked_by).to be_nil
    end

    it 'still run when stopped without a shutdown timeout' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      thread, gate = run_and_hold
      dispatcher.stop
      sleep 0.1
      gate << true
      Timeout.timeout(10) { thread.join }

      expect(SimpleJob.runs).to eq 1
      expect(Delayed::Job.all).not_to include(job)
    end

    it 'are not counted as failed attempts with count_shutdown_interrupts' do
      Delayed::Worker.count_shutdown_interrupts = true
      job = Delayed::Job.enqueue(SimpleJob.new)
      thread, gate = run_and_hold
      dispatcher.quit
      gate << true
      Timeout.timeout(10) { thread.join }
      expect(job.reload.attempts).to eq 0
    end

    it 'publish jobs_released' do
      events = payloads_of(:jobs_released)
      Delayed::Job.enqueue(SimpleJob.new)
      thread, gate = run_and_hold
      dispatcher.quit
      gate << true
      Timeout.timeout(10) { thread.join }
      expect(events).to eq [{:workers => [dispatcher.workers.first.name], :count => 1, :reason => 'shutdown'}]
    end
  end

  describe 'stopping without #stop (exit_on_complete, a crashed thread)' do
    it 'counts as stopping, so a job handed over past the shutdown deadline is released, not started' do
      Delayed::Worker.shutdown_timeout = 0
      d = Delayed::Dispatcher.new(:threads => 1)
      allow(d).to receive(:say)
      d.send(:start_threads)
      allow(d).to receive(:wait_for_threads)
      expect(d.send(:past_shutdown_deadline?)).to be false
      d.send(:stop_threads, nil)
      expect(d).to be_stop
      expect(d.send(:past_shutdown_deadline?)).to be true
    end

    it 'shows stopping in the procline' do
      Delayed::Worker.exit_on_complete = true
      d = Delayed::Dispatcher.new(:threads => 1, :procline => 'dj')
      allow(d).to receive(:say)
      titles = []
      allow(d).to receive(:update_procline).and_wrap_original do |m|
        m.call
        titles << d.procline
      end
      Timeout.timeout(5) { d.run }
      expect(titles.last).to start_with 'dj: stopping, '
    ensure
      $0 = 'rspec' if d
    end
  end

  describe 'a signal exception that reaches the dispatcher late (JRuby)' do
    it 'still interrupts and releases the running jobs past the deadline, then raises it' do
      Delayed::Worker.shutdown_timeout = 0
      job, = enqueue(GateJob.new(:a))
      calls = 0
      allow(dispatcher).to(receive(:wait_for_threads).and_wrap_original do |m|
        raise SignalException, 'TERM' if (calls += 1) == 1 # Arrives while waiting.

        m.call
      end)
      allow(dispatcher).to receive(:raise_in_threads) # As if it missed the job.
      thread = Thread.new { dispatcher.run }
      thread.report_on_exception = false
      Timeout.timeout(5) { GateJob.started.pop }
      dispatcher.stop
      expect { Timeout.timeout(10) { thread.join } }.to raise_error(SignalException, 'SIGTERM')
      expect(GateJob.interrupted).to eq [:a]
      expect(job.reload.locked_by).to be_nil
    end
  end

  describe 'shutting down with a deadline' do
    it 'waits for every thread, running a job or not, before returning' do
      d = Delayed::Dispatcher.new(:threads => 3, :sleep_delay => 0.05)
      silence_say(*and_workers(d))
      exiting = Queue.new
      Delayed::Worker.lifecycle.before(:perform) { |_worker, _job| Thread.current[:ran_job] = true }
      Delayed::Worker.lifecycle.after(:execute) do |_worker|
        # Slow callbacks (e.g. ClearLocks on a remote database) on the
        # threads that ran no job: the busy one is done long before them.
        sleep 0.5 unless Thread.current[:ran_job]
        exiting << Thread.current
      end
      Delayed::Job.enqueue(GateJob.new(:a))
      thread = Thread.new { d.run }
      Timeout.timeout(5) { GateJob.started.pop }
      d.quit
      Timeout.timeout(10) { thread.join }

      expect(exiting.size).to eq 3 # Every thread ran its :execute callbacks.
      expect(d.instance_variable_get(:@threads)).to all(satisfy { |t| !t.alive? })
    end
  end

  describe '#quit' do
    it 'interrupts running jobs at once, even without a shutdown timeout' do
      jobs = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      took = elapsed do
        dispatcher.quit
        Timeout.timeout(5) { thread.join }
      end

      expect(took).to be < 1 # At once, not after the job (which never ends by itself).
      expect(dispatcher).to be_quit
      expect(dispatcher).to be_stop
      expect(GateJob.interrupted).to eq [:a]
      expect(jobs.first.locked_by).to be_nil
      expect(jobs.first.attempts).to eq 0
      expect(log.map(&:last)).to include('Quitting: interrupting 1 running job(s)')
    end

    it 'takes effect while waiting for jobs after a stop' do
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      sleep 0.3
      expect(thread).to be_alive
      took = elapsed do
        dispatcher.quit
        Timeout.timeout(5) { thread.join }
      end
      expect(took).to be < 1 # At once, not after the job (which never ends by itself).
      expect(GateJob.interrupted).to eq [:a]
    end
  end

  describe 'signal traps' do
    let(:traps) { {} }

    before do
      allow(dispatcher).to receive(:trap) { |signal, &block| traps[signal] = block }
      dispatcher.send(:trap_signals)
    end

    it 'stops on TERM and INT' do
      traps['TERM'].call
      expect(dispatcher).to be_stop
      expect(dispatcher).not_to be_quit
    end

    it 'quits on QUIT' do
      skip_unless_quit_trappable
      traps['QUIT'].call
      expect(dispatcher).to be_quit
    end

    context 'with raise_signal_exceptions' do
      before { Delayed::Worker.raise_signal_exceptions = true }
      after { Delayed::Worker.raise_signal_exceptions = false }

      it 'raises the signal in the main thread when the trap runs on another thread (JRuby)' do
        expect(Thread.main).to receive(:raise).with(SignalException, 'TERM')
        Thread.new { traps['TERM'].call }.join
        expect(dispatcher).to be_stop
      end

      it 'raises the signal in the trap itself on the main thread (CRuby)' do
        skip 'needs the spec to run on the main thread' unless Thread.current == Thread.main
        expect(Thread.main).not_to receive(:raise)
        expect { traps['TERM'].call }.to raise_error(SignalException, 'SIGTERM')
      end

      it 'raises only for the first signal, so a repeated signal cannot interrupt the shutdown' do
        expect { traps['TERM'].call }.to raise_error(SignalException)
        expect { traps['TERM'].call }.not_to raise_error
        expect { traps['INT'].call }.not_to raise_error
      end
    end
  end

  describe 'signal traps where QUIT cannot be trapped (the JVM)' do
    let(:traps) { {} }

    before do
      allow(dispatcher).to receive(:trap) do |signal, &block|
        raise ArgumentError, "can't trap reserved signal: SIGQUIT" if signal == 'QUIT'
        traps[signal] = block
      end
    end

    it 'still traps TERM and INT' do
      expect { dispatcher.send(:trap_signals) }.not_to raise_error
      expect(traps.keys).to contain_exactly('TERM', 'INT')
      traps['TERM'].call
      expect(dispatcher).to be_stop
    end

    it 'warns that QUIT is not trapped' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      dispatcher.send(:trap_signals)
      expect(log).to include(['warn', "WARNING: cannot trap SIGQUIT on this platform (can't trap reserved signal: " \
                                      'SIGQUIT); use TERM or INT to stop'])
    end

    it 'does not warn when QUIT can be trapped' do
      skip_unless_quit_trappable
      allow(dispatcher).to receive(:trap) { |signal, &block| traps[signal] = block }
      dispatcher.send(:trap_signals)
      expect(log.map(&:last).grep(/SIGQUIT/)).to be_empty
    end

    it 'does not try to trap QUIT where there is no such signal' do
      allow(Signal).to receive(:list).and_return(Signal.list.reject { |name, _| name == 'QUIT' })
      expect(dispatcher).not_to receive(:trap).with('QUIT')
      dispatcher.send(:trap_signals)
      expect(log.map(&:last).grep(/SIGQUIT/)).to be_empty
    end

    it 'still starts and runs' do
      Delayed::Worker.exit_on_complete = true
      job = Delayed::Job.enqueue(SimpleJob.new)
      SimpleJob.runs = 0
      Timeout.timeout(5) { dispatcher.start }
      expect(Delayed::Job.all).not_to include(job)
    end
  end

  describe 'Worker.count_shutdown_interrupts' do
    before { Delayed::Worker.shutdown_timeout = 0 }

    def interrupt_running(job_payload)
      job = Delayed::Job.enqueue(job_payload)
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(10) { thread.join }
      job.reload
    end

    it 'is off by default, set by Worker.new options, and reset' do
      expect(Delayed::Worker.count_shutdown_interrupts).to be false
      Delayed::Worker.new(:count_shutdown_interrupts => true)
      expect(Delayed::Worker.count_shutdown_interrupts).to be true
      Delayed::Worker.reset
      expect(Delayed::Worker.count_shutdown_interrupts).to be false
    end

    it 'when off, releases an interrupted job with its attempts unchanged' do
      job = interrupt_running(GateJob.new(:a))
      expect([job.attempts, job.locked_by, job.last_error]).to eq [0, nil, nil]
    end

    context 'when on' do
      before { Delayed::Worker.count_shutdown_interrupts = true }

      it 'counts an interrupted job as a failed attempt, rescheduled with back-off' do
        run_at = Delayed::Job.db_time_now
        job = interrupt_running(GateJob.new(:a))
        expect(GateJob.interrupted).to eq [:a]
        expect(job.attempts).to eq 1
        expect(job.locked_by).to be_nil
        expect(job.locked_at).to be_nil
        expect(job.run_at).to be > run_at
        expect(job.last_error).to start_with 'Shutdown timeout of 0s exceeded'
        expect(log.map(&:last).grep(/interrupted by shutdown; counted as a failed attempt/).size).to eq 1
        expect(log.map(&:last).grep(/released for another worker/)).to be_empty
      end

      it 'fails a job permanently once it used up its attempts' do
        Delayed::Worker.max_attempts = 1
        Delayed::Worker.destroy_failed_jobs = false
        job = interrupt_running(GateJob.new(:a))
        expect(job.failed_at).not_to be_nil
        expect(job.attempts).to eq 1
      ensure
        Delayed::Worker.destroy_failed_jobs = true
      end

      it 'runs :error callbacks' do
        dispatcher # Worker.new resets the lifecycle.
        errors = []
        Delayed::Worker.lifecycle.before(:error) { |_w, job| errors << job.id }
        job = interrupt_running(GateJob.new(:a))
        expect(errors).to eq [job.id]
      end

      it 'counts a job interrupted by QUIT too' do
        job = Delayed::Job.enqueue(GateJob.new(:a))
        thread = run_until_started(1)
        dispatcher.quit
        Timeout.timeout(10) { thread.join }
        job.reload
        expect(job.attempts).to eq 1
        expect(job.last_error).to start_with 'Quitting'
      end

      it 'does not count jobs that finished before the shutdown' do
        Delayed::Worker.shutdown_timeout = nil
        job = Delayed::Job.enqueue(GateJob.new(:a))
        thread = run_until_started(1)
        dispatcher.stop
        GateJob.release = true
        Timeout.timeout(10) { thread.join }
        expect(Delayed::Job.all).not_to include(job)
      end

      it 'still releases the lock when recording the attempt fails' do
        allow_any_instance_of(Delayed::Worker).to receive(:fail_attempt).and_raise(IOError, 'db down')
        allow(Delayed::Job).to receive(:clear_locks!).and_call_original
        interrupt_running(GateJob.new(:a))
        expect(log.map(&:last).grep(/Could not release the jobs of .*IOError: db down/).size).to eq 1
      end
    end
  end

  describe 'Worker#initialize' do
    it 'sets the shutdown timeout' do
      Delayed::Worker.new(:shutdown_timeout => 12.5)
      expect(Delayed::Worker.shutdown_timeout).to eq 12.5
    end

    it 'defaults to nil' do
      expect(Delayed::Worker.shutdown_timeout).to be_nil
    end
  end
end

describe Delayed::Launcher::Forking, 'stopping worker processes' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap) { |signal, &block| traps[signal] = block }
    launcher.send(:workers).merge!(11 => ['delayed_job.0', {}], 12 => ['delayed_job.1', {}])
    launcher.send(:trap_signals)
  end

  after { Delayed::Worker.reset }

  %w[TERM INT].each do |signal|
    describe "on SIG#{signal}" do
      it 'stops the run loop and forwards the signal to every worker' do
        expect(Process).to receive(:kill).with(signal, 11)
        expect(Process).to receive(:kill).with(signal, 12)
        expect(launcher).not_to receive(:schedule_kill)
        traps[signal].call
        expect(launcher.instance_variable_get(:@stopped)).to be true
      end

      it 'ignores workers that already exited' do
        allow(Process).to receive(:kill).with(signal, 11).and_raise(Errno::ESRCH)
        expect(Process).to receive(:kill).with(signal, 12)
        expect { traps[signal].call }.not_to raise_error
      end

      context 'with a shutdown timeout' do
        let(:options) { {:processes => 2, :shutdown_timeout => 20} }

        it 'kills workers still running SHUTDOWN_GRACE seconds after it' do
          allow(Process).to receive(:kill)
          expect(launcher).to receive(:schedule_kill).with(20 + described_class::SHUTDOWN_GRACE)
          traps[signal].call
        end
      end

      it 'uses Worker.shutdown_timeout when no option is given' do
        Delayed::Worker.shutdown_timeout = 7
        allow(Process).to receive(:kill)
        expect(launcher).to receive(:schedule_kill).with(7 + described_class::SHUTDOWN_GRACE)
        traps[signal].call
      end
    end
  end

  describe 'on SIGQUIT' do
    before { skip_unless_quit_trappable }

    it 'forwards QUIT to every worker and kills those still running after SHUTDOWN_GRACE seconds' do
      expect(Process).to receive(:kill).with('QUIT', 11)
      expect(Process).to receive(:kill).with('QUIT', 12)
      expect(launcher).to receive(:schedule_kill).with(described_class::SHUTDOWN_GRACE)
      traps['QUIT'].call
      expect(launcher.instance_variable_get(:@stopped)).to be true
    end
  end

  describe '#signal_workers' do
    it 'signals every worker' do
      expect(Process).to receive(:kill).with('KILL', 11)
      expect(Process).to receive(:kill).with('KILL', 12)
      launcher.send(:signal_workers, 'KILL')
      expect(logger).to have_received(:info).with('Sent SIGKILL to child process delayed_job.0 (pid 11)')
    end

    it 'skips workers that already exited, and still signals the others' do
      allow(Process).to receive(:kill).with('KILL', 11).and_raise(Errno::ESRCH)
      expect(Process).to receive(:kill).with('KILL', 12)
      expect { launcher.send(:signal_workers, 'KILL') }.not_to raise_error
      expect(logger).to have_received(:info).with('Child process delayed_job.0 (pid 11) already exited; not sent SIGKILL')
      expect(logger).to have_received(:info).with('Sent SIGKILL to child process delayed_job.1 (pid 12)')
    end

    it 'is not disturbed by the run loop reaping a worker meanwhile' do
      allow(Process).to receive(:kill) do |_signal, pid|
        launcher.send(:workers).delete(12) if pid == 11 # Reaped by the main thread.
      end
      expect { launcher.send(:signal_workers, 'KILL') }.not_to raise_error
      expect(Process).to have_received(:kill).twice
    end
  end

  describe 'the workers list' do
    it 'forwards a signal from a copy, while the run loop removes workers' do
      allow(Process).to receive(:kill) do |_signal, pid|
        launcher.send(:workers).delete(12) if pid == 11 # Reaped meanwhile.
      end
      expect { traps['TERM'].call }.not_to raise_error
      expect(Process).to have_received(:kill).with('TERM', 11)
    end
  end

  describe '#kill' do
    it 'SIGKILLs the workers, skipping one that already exited, without exiting' do
      allow(Process).to receive(:kill).with('KILL', 11).and_raise(Errno::ESRCH)
      allow(Process).to receive(:kill).with('KILL', 12)
      expect(launcher).not_to receive(:exit)
      launcher.kill('after 30 second timeout')
      expect(Process).to have_received(:kill).with('KILL', 12)
      expect(logger).to have_received(:warn).with('Kill invoked after 30 second timeout')
      expect(launcher).to be_stopped
    end

    it 'leaves the launch to exit with status 1, once the run loop has reaped the workers' do
      allow(Process).to receive(:kill)
      launcher.kill('after 30 second timeout')
      expect { launcher.send(:exit_forcefully) }.to raise_error(SystemExit) { |e| expect(e.status).to eq 1 }
      expect(logger).to have_received(:warn).with(/exited forcefully after 30 second timeout/)
    end
  end

  describe 'the kill timer thread' do
    before { stub_const("#{described_class}::SHUTDOWN_GRACE", 0.05) }

    it 'kills, then exits regardless if the run loop is still stuck SHUTDOWN_GRACE later' do
      allow(Process).to receive(:kill)
      exited = Queue.new
      allow(launcher).to receive(:exit!) { |status| exited << status }
      launcher.send(:schedule_kill, 0.01)
      expect(Timeout.timeout(2) { exited.pop }).to eq 1
      expect(Process).to have_received(:kill).with('KILL', 11)
      expect(logger).to have_received(:error).with(/still running 0.05s after the kill; exiting/)
    end
  end

  describe '#schedule_kill' do
    before { allow(launcher).to receive(:exit_stuck) } # Would exit! this process.

    it 'kills the workers after the timeout' do
      expect(launcher).to receive(:kill).with('after 0.05 second timeout')
      launcher.send(:schedule_kill, 0.05).join(2)
    end

    it 'keeps the earliest kill when called again' do
      allow(launcher).to receive(:kill)
      first = launcher.send(:schedule_kill, 0.05)
      expect(launcher.send(:schedule_kill, 30)).to be_nil
      first.join(2)
      expect(launcher).to have_received(:kill).once
    end

    # Kill timers that outlive their example would fire, for real, in a later one.
    after { Thread.list.select { |t| t.backtrace.to_a.any? { |l| l.include?('schedule_kill') } }.each(&:kill) }

    it 'schedules an earlier kill' do
      allow(launcher).to receive(:kill)
      launcher.send(:schedule_kill, 30)
      sooner = launcher.send(:schedule_kill, 0.05)
      expect(sooner).to be_a Thread
      sooner.join(2)
      expect(launcher).to have_received(:kill).with('after 0.05 second timeout')
    end
  end
end

describe Delayed::Launcher::Forking, 'on SIGHUP' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    skip 'no SIGHUP on this platform' unless Signal.list.key?('HUP')
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap) { |signal, *args, &block| traps[signal] = block || args.first }
    launcher.send(:workers).merge!(11 => ['delayed_job.0', {}], 12 => ['delayed_job.1', {}])
  end

  it 'stops gracefully, forwarding TERM to every worker, instead of exiting (and deleting the pidfile)' do
    launcher.send(:trap_signals)
    expect(Process).to receive(:kill).with('TERM', 11)
    expect(Process).to receive(:kill).with('TERM', 12)
    traps['HUP'].call
    expect(launcher.instance_variable_get(:@stopped)).to be true
    expect(launcher.send(:add_worker, {})).to be_nil
  end

  it 'kills workers still running SHUTDOWN_GRACE seconds after the shutdown timeout' do
    options[:shutdown_timeout] = 20
    launcher.send(:trap_signals)
    allow(Process).to receive(:kill)
    expect(launcher).to receive(:schedule_kill).with(20 + described_class::SHUTDOWN_GRACE)
    traps['HUP'].call
  end

  it 'is ignored by a freshly forked child (the parent sends it TERM)' do
    launcher.send(:trap_signals)
    launcher.instance_variable_set(:@launcher_pid, Process.pid + 1)
    expect(Process).not_to receive(:kill)
    traps['HUP'].call
    expect(launcher.send(:child_signals)).to be_empty
    launcher.send(:capture_signals)
    # A no-op handler rather than 'IGNORE', which would outlive exec in
    # commands jobs run.
    expect(traps['HUP']).to be_a(Proc)
    expect { traps['HUP'].call }.not_to(change { launcher.send(:child_signals).size })
  end

  context 'with a single worker process (not forked)' do
    let(:options) { {} }

    it 'is left to its default' do
      launcher.send(:trap_signals)
      expect(traps).not_to have_key('HUP')
    end
  end
end

describe Delayed::Launcher::Forking, 'checking the settings before forking' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }

  before do
    allow(launcher).to receive(:setup_logger)
    allow(launcher).to receive(:fork_worker)
    allow(launcher).to receive(:trap_signals)
  end

  it 'refuses a prefetch set in an initializer beyond the maximum, forking nothing' do
    Delayed::Worker.prefetch = 30
    expect { launcher.launch }.to raise_error(ArgumentError, /prefetch must be a whole number from 0 to 20 \(got 30\)/)
    expect(launcher).not_to have_received(:fork_worker)
  end

  it 'refuses a heartbeat that the lock_timeout set in an initializer would let locks expire between' do
    Delayed::Worker.lock_timeout = 60
    options[:lock_heartbeat_interval] = 45
    expect { launcher.launch }.to raise_error(ArgumentError, /lock_timeout \(60\) must be at least twice lock_heartbeat_interval \(45\)/)
    expect(launcher).not_to have_received(:fork_worker)
  end

  it 'lets options override the Worker settings' do
    Delayed::Worker.prefetch = 30
    Delayed::Worker.lock_timeout = 60
    expect { Delayed::Worker.validate_settings!(:prefetch => 2, :lock_heartbeat_interval => 10, :lock_timeout => 30) }.not_to raise_error
    expect { Delayed::Worker.validate_settings!(:prefetch => 21) }.to raise_error(ArgumentError, /got 21/)
  end
end

describe Delayed::Launcher::Forking, 'a signal that arrives while the launcher boots' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }
  let(:forked) { [] }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(launcher).to receive(:setup_logger)
    allow(Signal).to receive(:trap) { |signal, &block| traps[signal] = block }
    allow(Delayed::Worker).to receive(:before_fork)
    allow(launcher).to receive(:run_loop)
    allow(launcher).to receive(:fork_worker) do |name, _|
      forked << name
      100 + forked.size
    end
    allow(Process).to receive(:kill)
  end

  %w[TERM INT].each do |signal|
    it "forks no worker after SIG#{signal} during prepare_for_fork, so none is left running" do
      allow(launcher).to receive(:prepare_for_fork) { traps[signal].call }
      launcher.launch
      expect(forked).to be_empty
      expect(launcher.send(:workers)).to be_empty
    end
  end

  it 'sends the signal to a child forked as it arrived (the trap only reached the children recorded then)' do
    allow(launcher).to receive(:prepare_for_fork)
    allow(launcher).to receive(:fork_worker) do |name, _|
      forked << name
      traps['TERM'].call if forked.size == 1 # Arrives during the fork: no child is recorded yet.
      100 + forked.size
    end
    launcher.launch
    expect(forked.size).to eq 1
    expect(Process).to have_received(:kill).with('TERM', 101)
  end

  it 'replaces no worker once stopped by a signal' do
    launcher.send(:trap_signals)
    traps['TERM'].call
    expect(launcher.send(:add_worker, {}, :replaces_pid => 7)).to be_nil
    expect(forked).to be_empty
  end

  it 'still forks the workers with exit_on_complete (stopped, but not by a signal)' do
    options[:exit_on_complete] = true
    allow(launcher).to receive(:prepare_for_fork)
    launcher.launch
    expect(forked.size).to eq 2
    expect(Process).not_to have_received(:kill)
  end

  context 'with a single worker process' do
    let(:options) { {} }

    it 'hands the signal to the dispatcher, which stops before running any job' do
      dispatcher = instance_double(Delayed::Dispatcher)
      allow(Delayed::Dispatcher).to receive(:new).and_return(dispatcher)
      allow(launcher).to receive(:set_process_name)
      allow(launcher).to receive(:trap_signals).and_wrap_original do |m|
        m.call
        traps['TERM'].call # Before the dispatcher installs its own traps.
      end
      expect(dispatcher).to receive(:start).with(['TERM'])
      launcher.launch
    end
  end
end

describe Delayed::Dispatcher, 'shutdown timeout message' do
  it 'formats whole and fractional seconds the same way, whatever their type' do
    dispatcher = described_class.new
    messages = Concurrent::Array.new
    allow(dispatcher).to receive(:say) { |text, *| messages << text }
    thread = Thread.new { sleep }
    [1, 1.0, 2.5].each do |timeout|
      Delayed::Worker.shutdown_timeout = timeout
      stub_const('Delayed::Dispatcher::INTERRUPT_GRACE', 0)
      allow(thread).to receive(:raise)
      dispatcher.send(:interrupt_threads, [thread], Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end
    expect(messages.grep(/Shutdown timeout/)).to eq [
      'Shutdown timeout of 1s exceeded: interrupting 1 running job(s)',
      'Shutdown timeout of 1s exceeded: interrupting 1 running job(s)',
      'Shutdown timeout of 2.5s exceeded: interrupting 1 running job(s)'
    ]
  ensure
    thread.kill
    Delayed::Worker.reset
  end
end

describe Delayed::Launcher::Forking, 'where QUIT cannot be trapped (the JVM)' do
  subject(:launcher) { described_class.new(:processes => 2) }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap) do |signal, *_args, &block|
      raise ArgumentError, "can't trap reserved signal: SIGQUIT" if signal == 'QUIT'
      traps[signal] = block
    end
  end

  it 'still traps TERM and INT, and warns about QUIT' do
    skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
    expect { launcher.send(:trap_signals) }.not_to raise_error
    expect(traps.keys).to contain_exactly('TERM', 'INT', 'HUP')
    expect(logger).to have_received(:warn).with("Cannot trap SIGQUIT on this platform (can't trap reserved signal: " \
                                                 'SIGQUIT); use TERM or INT to stop')
  end

  it 'still forwards TERM to its workers' do
    launcher.send(:workers).merge!(11 => ['delayed_job.0', {}])
    launcher.send(:trap_signals)
    expect(Process).to receive(:kill).with('TERM', 11)
    traps['TERM'].call
  end

  it 'still records TERM and INT in a starting worker process' do
    pending_signals = launcher.send(:capture_signals)
    expect(traps.keys).to contain_exactly('TERM', 'INT', 'HUP')
    traps['TERM'].call
    expect(pending_signals).to eq ['TERM']
  end

  it 'can still launch' do
    allow(launcher).to receive(:setup_logger)
    allow(launcher).to receive(:prepare_for_fork)
    allow(launcher).to receive(:setup_workers)
    allow(launcher).to receive(:run_loop)
    allow(Delayed::Worker).to receive(:before_fork)
    expect { launcher.launch }.not_to raise_error
  end
end

describe Delayed::Launcher::Forking, 'traps inherited by a freshly forked child process' do
  subject(:launcher) { described_class.new(:processes => 2, :shutdown_timeout => 5) }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap) { |signal, *_args, &block| traps[signal] = block }
    launcher.instance_variable_set(:@launcher_pid, Process.pid)
    launcher.send(:workers).merge!(11 => ['delayed_job.0', {}], 12 => ['delayed_job.1', {}])
    launcher.send(:trap_signals)
  end

  %w[TERM INT QUIT].each do |signal|
    context "on SIG#{signal}" do
      before { skip_unless_quit_trappable if signal == 'QUIT' }

      it 'only record it, in a child process' do
        allow(Process).to receive(:pid).and_return(Process.pid + 1)
        expect(Process).not_to receive(:kill)
        expect(launcher).not_to receive(:schedule_kill)
        traps[signal].call
        expect(launcher.instance_variable_get(:@stopped)).to be_falsey
        expect(launcher.send(:child_signals)).to eq [signal]
      end

      it 'still stop and forward it in the launcher itself' do
        allow(Process).to receive(:kill)
        allow(launcher).to receive(:schedule_kill)
        traps[signal].call
        expect(launcher.instance_variable_get(:@stopped)).to be true
        expect(Process).to have_received(:kill).with(signal, 11)
        expect(launcher.send(:child_signals)).to be_empty
      end
    end
  end

  it 'hand the recorded signals to the child, once each, with those captured later' do
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    traps['TERM'].call
    traps['TERM'].call
    pending = launcher.send(:capture_signals)
    expect(pending).to eq ['TERM']
    traps['INT'].call # Now the capturing trap.
    expect(pending).to eq %w[TERM INT]
  end

  it 'hand on a signal that arrives while the child replaces them' do
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    inherited = traps['TERM']
    replaced = 0
    allow(Signal).to receive(:trap) do |signal, *_args, &block|
      # TERM is handled by the inherited trap just before the first
      # capturing trap is installed.
      inherited.call if (replaced += 1) == 1
      traps[signal] = block
    end
    pending = launcher.send(:capture_signals)
    expect(pending).to eq ['TERM']
  end

  it 'record nothing before the launcher starts (no launcher pid yet)' do
    launcher.instance_variable_set(:@launcher_pid, nil)
    allow(Process).to receive(:kill)
    expect(launcher).to receive(:schedule_kill) # Stubbed: a real one would exit this process.
    traps['TERM'].call
    expect(launcher.instance_variable_get(:@stopped)).to be true
  end
end

describe 'Signals received while a worker process starts up' do
  describe 'Delayed::Launcher::Forking#capture_signals' do
    subject(:launcher) { Delayed::Launcher::Forking.new(:processes => 2) }

    around do |example|
      previous = %w[TERM INT QUIT].select { |s| Signal.list.key?(s) }.map { |s| [s, Signal.trap(s, 'DEFAULT')] }
      example.run
    ensure
      previous.each { |signal, handler| Signal.trap(signal, handler || 'DEFAULT') }
    end

    it "replaces the parent's traps with ones that only record the signal" do
      parent_trap_ran = false
      Signal.trap('TERM') { parent_trap_ran = true }
      pending = launcher.send(:capture_signals)

      Process.kill('TERM', Process.pid)
      Process.kill('INT', Process.pid)
      wait_until(2) { pending.size == 2 }

      expect(pending).to contain_exactly('TERM', 'INT') # Their order isn't guaranteed (JRuby).
      expect(parent_trap_ran).to be false
    end

    # On JRuby, each signal trap runs on a thread of its own, in parallel.
    it 'loses no signal recorded by traps running at once' do
      threads = Array.new(8) do |t|
        Thread.new do
          100.times do |i|
            launcher.send(:child_signal, "S#{t}-#{i}")
            launcher.send(:stop_signals) << "S#{t}-#{i}"
          end
        end
      end
      threads.each(&:join)
      expect(launcher.send(:child_signals).size).to eq 800
      expect(launcher.send(:stop_signals).compact.size).to eq 800
    end

    it 'records each signal once, though it may arrive twice' do
      pending = launcher.send(:capture_signals)
      Process.kill('TERM', Process.pid)
      wait_until(2) { pending.any? }
      Process.kill('TERM', Process.pid)
      sleep 0.1
      expect(pending).to eq ['TERM']
    end

    it 'records QUIT' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      skip 'the JVM reserves SIGQUIT' if RUBY_ENGINE == 'jruby'
      pending = launcher.send(:capture_signals)
      Process.kill('QUIT', Process.pid)
      wait_until(2) { pending.any? }
      expect(pending).to eq ['QUIT']
    end

    it 'is called first in the forked worker, and its signals are passed to the worker' do
      pending = ['TERM']
      allow(launcher).to receive(:fork) { |&block|
        block.call
        123
      }
      expect(launcher).to receive(:capture_signals).ordered.and_return(pending)
      expect(launcher).to receive(:run_worker).with('delayed_job.0', {}, pending).ordered
      expect(launcher.send(:fork_worker, 'delayed_job.0', {})).to eq 123
    end
  end

  describe Delayed::Dispatcher do
    let(:dispatcher) { described_class.new }

    before do
      allow(dispatcher).to receive(:trap_signals)
      allow(dispatcher).to receive(:say)
    end

    it 'stops before running when it received TERM or INT while starting' do
      %w[TERM INT].each do |signal|
        d = described_class.new
        allow(d).to receive(:trap_signals)
        allow(d).to receive(:say)
        expect(Delayed::Job).not_to receive(:reserve_batch)
        Timeout.timeout(5) { d.start([signal]) }
        expect(d).to be_stop
        expect(d).not_to be_quit
        expect(d).to have_received(:say).with("Received SIG#{signal} while starting", 'warn')
      end
    end

    it 'quits when it received QUIT while starting' do
      Timeout.timeout(5) { dispatcher.start(['QUIT']) }
      expect(dispatcher).to be_quit
    end

    it 'does not raise a SignalException for them, even with raise_signal_exceptions' do
      Delayed::Worker.raise_signal_exceptions = true
      expect { Timeout.timeout(5) { dispatcher.start(['TERM']) } }.not_to raise_error
    ensure
      Delayed::Worker.raise_signal_exceptions = false
    end

    it 'installs its traps before handling them, so later signals are not lost' do
      expect(dispatcher).to receive(:trap_signals).ordered
      expect(dispatcher).to receive(:handle_pending_signal).with('TERM').ordered.and_call_original
      expect(dispatcher).to receive(:run).ordered
      dispatcher.start(['TERM'])
    end

    it 'runs normally without pending signals' do
      expect(dispatcher).to receive(:run)
      dispatcher.start
      expect(dispatcher).not_to be_stop
    end
  end

  describe 'Delayed::Launcher::Base#run_worker' do
    it 'passes the pending signals to the dispatcher' do
      launcher = Delayed::Launcher::Forking.new(:processes => 2)
      allow(Dir).to receive(:chdir)
      allow(Delayed::Worker).to receive(:after_fork)
      allow(launcher).to receive(:setup_logger)
      dispatcher = double(:name_prefix= => nil, :cleanly_stopped? => true)
      allow(Delayed::Dispatcher).to receive(:new).and_return(dispatcher)
      expect(dispatcher).to receive(:start).with(['TERM'])
      launcher.send(:run_worker, 'delayed_job.0', {}, ['TERM'])
    end
  end
end
