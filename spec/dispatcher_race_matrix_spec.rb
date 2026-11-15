require 'helper'

# Interleavings in the in-process Dispatcher (worker threads, prefetch slots,
# the lock heartbeat, stop/quit/promote), each forced with gates rather than
# sleeps: a stub blocks one thread at the chosen point until the example
# opens the gate.
describe 'Dispatcher race matrix' do
  let(:log) { Concurrent::Array.new }
  let(:crash_error) { Class.new(Exception) } # rubocop:disable Lint/InheritException -- escapes job handling

  before do
    Delayed::Job.delete_all
    GateJob.reset
    SimpleJob.runs = 0
  end

  def dispatcher(threads, options = {})
    Delayed::Dispatcher.new({:threads => threads, :sleep_delay => 0.05}.merge(options)).tap { |d| capture_say(log, *and_workers(d)) }
  end

  def ivar(object, name)
    object.instance_variable_get(:"@#{name}")
  end

  # Slots and inboxes, without threads (unit-level interleavings).
  def prepare(dispatcher)
    dispatcher.send(:build_slots)
    dispatcher.workers.each { |w| ivar(dispatcher, :inboxes)[w] = Delayed::Inbox.new }
    dispatcher
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def unlocked?(job)
    job.locked_by.nil? && job.locked_at.nil? && job.attempts.zero?
  end

  def gate_jobs(count)
    Array.new(count) { |i| Delayed::Job.enqueue(GateJob.new(i)) }
  end

  # Blocks the next reserve_batch (once armed) before it queries, until the
  # returned gate is opened. `entered` gets a value once it blocks.
  def gate_next_reservation(armed, entered)
    gate = Queue.new
    allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, *args|
      if armed.make_false # The first call after arming only.
        entered << true
        gate.pop
      end
      m.call(*args)
    end
    gate
  end

  describe 'a worker thread crashing while a poll for its free prefetch slot is under way' do
    before { Delayed::Worker.prefetch = 1 }

    it 'leaves no job locked under the dead thread\'s slot names' do
      d = dispatcher(1)
      started = Queue.new
      crash = Queue.new
      error = crash_error
      allow(d.workers.first).to receive(:perform_job) do
        started << true
        crash.pop
        raise error, 'boom'
      end
      armed = Concurrent::AtomicBoolean.new(false)
      entered = Queue.new
      gate = gate_next_reservation(armed, entered)
      first = Delayed::Job.enqueue(SimpleJob.new)
      thread = run_in_thread(d)
      Timeout.timeout(5) { started.pop } # Running in slot:0; slot:1 is free.
      armed.make_true
      Timeout.timeout(5) { entered.pop } # A poll for slot:1 is under way...
      queued = Delayed::Job.enqueue(SimpleJob.new)
      crash << :go # ...as the thread crashes,
      expect(ivar(d, :threads).first.join(5)).to be_truthy # clears its slot locks, and exits.
      gate << :go # The poll now locks the job under the dead thread's slot:1.
      expect { Timeout.timeout(5) { thread.join } }.to raise_error(error, 'boom')
      # The poll takes whichever is first: the crashed job, unlocked by now.
      expect([first.locked_by, queued.locked_by]).to eq [nil, nil]
    end
  end

  describe 'quit landing between a thread\'s shutdown check and the start of its job' do
    it 'does not leave the job running, uninterrupted, once #run returned' do
      stub_const('Delayed::Dispatcher::INTERRUPT_GRACE', 0.5) # Keeps the example short.
      job, = gate_jobs(1)
      d = dispatcher(1)
      entered = Queue.new
      gate = Queue.new
      # Called right after work_jobs' past_shutdown_deadline? check, before
      # run_job records the thread as running.
      allow(d).to receive(:lock_time_left).and_wrap_original do |m, *args|
        entered << true
        gate.pop
        m.call(*args)
      end
      interrupted = Queue.new
      allow(d).to receive(:interrupt_threads).and_wrap_original do |m, busy, deadline|
        m.call(busy, deadline).tap { interrupted << busy.size }
      end
      thread = run_in_thread(d)
      Timeout.timeout(5) { entered.pop }
      d.quit
      Timeout.timeout(5) { interrupted.pop } # Interrupts went out: none for this thread.
      gate << :go
      Timeout.timeout(5) { thread.join }
      worker_thread = ivar(d, :threads).first
      begin
        expect(worker_thread.join(1)).to be_truthy
        expect(job.locked_by).to be_nil
      ensure
        GateJob.release = true # Don't leak a running job into later examples.
        worker_thread.join(5)
      end
    end
  end

  describe 'a stop or quit arriving while a reservation is under way' do
    it 'starts none of the jobs a prefetching batch reserved after the stop, and unlocks them all' do
      Delayed::Worker.prefetch = 2
      jobs = gate_jobs(6)
      d = dispatcher(2)
      armed = Concurrent::AtomicBoolean.new(true)
      entered = Queue.new
      gate = gate_next_reservation(armed, entered)
      thread = run_in_thread(d)
      Timeout.timeout(5) { entered.pop }
      d.stop
      gate << :go # Reserves all 6, for 2 workers x 3 slots.
      Timeout.timeout(10) { thread.join }
      expect(GateJob.started.size).to eq 0
      expect(jobs).to all(satisfy { |job| unlocked?(job) })
      expect(ivar(d, :slot_jobs)).to be_empty
    end

    it 'starts none of the jobs reserved after a quit, without prefetch, and unlocks them' do
      jobs = gate_jobs(2)
      d = dispatcher(2)
      armed = Concurrent::AtomicBoolean.new(true)
      entered = Queue.new
      gate = gate_next_reservation(armed, entered)
      thread = run_in_thread(d)
      Timeout.timeout(5) { entered.pop }
      d.quit
      gate << :go
      Timeout.timeout(10) { thread.join }
      expect(GateJob.started.size).to eq 0
      expect(jobs).to all(satisfy { |job| unlocked?(job) })
      expect(log.map(&:last).grep(/not started before shutdown/).size).to eq 2
    end
  end

  describe 'signals arriving twice, or during a promotion (trap level)' do
    let(:traps) { {} }
    let(:d) { dispatcher(1, :procline => 'dj') }

    before do
      allow(d).to receive(:trap) { |signal, &block| traps[signal] = block }
      d.send(:trap_signals)
      Delayed::Worker.raise_signal_exceptions = true
    end

    after { Delayed::Worker.raise_signal_exceptions = false }

    it 'raises nothing for a TERM after QUIT, which would cut the quit short, and stays quitting' do
      skip_unless_quit_trappable
      traps['QUIT'].call
      expect { traps['TERM'].call }.not_to raise_error
      expect(d).to be_quit
      expect(d.procline).to start_with 'dj: quitting, '
    end

    it 'treats a TERM during a promotion as the first real stop: cancels it and raises the signal' do
      d.promote
      expect { traps['TERM'].call }.to raise_error(SignalException)
      expect(d).not_to be_promoted
      expect(d).to be_promotion_cancelled
      expect(d.procline).to start_with 'dj: stopping, '
    end

    it 'cancels a promotion on QUIT and quits' do
      skip_unless_quit_trappable
      d.promote
      traps['QUIT'].call
      expect(d).to be_promotion_cancelled
      expect(d).to be_quit
      expect(d.procline).to start_with 'dj: quitting, '
    end
  end

  describe 'a promotion and Worker.count_shutdown_interrupts' do
    before { Delayed::Worker.count_shutdown_interrupts = true }

    it 'never counts an attempt for a job interrupted by the promotion\'s shutdown timeout' do
      Delayed::Worker.shutdown_timeout = 0
      job, = gate_jobs(1)
      d = dispatcher(1)
      thread = run_in_thread(d)
      Timeout.timeout(5) { GateJob.started.pop }
      d.promote
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [0]
      expect(unlocked?(job)).to be true
    end

    it 'counts the attempt once a QUIT cancelled the promotion and interrupted the job' do
      job, = gate_jobs(1)
      d = dispatcher(1)
      thread = run_in_thread(d)
      Timeout.timeout(5) { GateJob.started.pop }
      d.promote # No shutdown timeout: the job would run on.
      d.cancel_promotion # What the QUIT trap does, then quits.
      d.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [0]
      expect([job.attempts, job.locked_by]).to eq [1, nil]
    end
  end

  describe 'the heartbeat and an overrun job that ends as the heartbeat looks at it' do
    before do
      Delayed::Worker.prefetch = 1
      Delayed::Worker.max_run_time = 10
    end

    # One worker running a job past its max_run_time, one job queued behind.
    def overrun_setup
      d = prepare(dispatcher(1))
      worker = d.workers.first
      running, queued = ivar(d, :slots)[worker]
      stuck = Delayed::Job.enqueue(SimpleJob.new)
      waiting = Delayed::Job.enqueue(SimpleJob.new)
      [[running, stuck], [queued, waiting]].each do |slot, job|
        job.locked_by = slot.name
        job.locked_at = Delayed::Job.db_time_now
        d.send(:dispatch, slot, job)
      end
      ivar(d, :inboxes)[worker].pop # The worker took the stuck job.
      ivar(d, :running_slot)[worker] = running
      ivar(d, :jobs_started)[worker] = [stuck, now - 11, 10, 'Job']
      [d, worker, running, queued, waiting]
    end

    it 'keeps refreshing the queued job the worker started meanwhile' do
      d, worker, running, queued, waiting = overrun_setup
      allow(d).to receive(:report_overrun).and_wrap_original do |m, *args|
        m.call(*args)
        # Between the overrun snapshot and the stuck-slot lookup: the overrun
        # job ends and the worker starts the queued one.
        d.send(:untrack_job_after, worker) { nil }
        d.send(:job_finished, worker, running, true)
        ivar(d, :inboxes)[worker].pop
        ivar(d, :running_slot)[worker] = queued
      end
      expect(d.send(:heartbeat_names)).to eq [queued.name]
      expect(waiting.locked_by).to eq queued.name
    end

    it 'releases each queued job once when the stuck release races the shutdown release' do
      Delayed::Worker.prefetch = 2
      d = prepare(dispatcher(1))
      worker = d.workers.first
      slots = ivar(d, :slots)[worker]
      jobs = slots.map do |slot|
        Delayed::Job.enqueue(SimpleJob.new).tap do |job|
          job.locked_by = slot.name
          job.locked_at = Delayed::Job.db_time_now
          d.send(:dispatch, slot, job)
        end
      end
      inbox = ivar(d, :inboxes)[worker]
      stuck = inbox.pop.last # Same priority: taken in dispatch order.
      ivar(d, :running_slot)[worker] = slots.first
      ivar(d, :jobs_started)[worker] = [stuck, now - 11, 10, 'Job']
      released = payloads_of(:jobs_released)
      entered = Queue.new
      gate = Queue.new
      first = Concurrent::AtomicBoolean.new(true)
      allow(Delayed::Job).to receive(:clear_locks!).and_wrap_original do |m, names|
        if first.make_false # The heartbeat's release, after it drained the inbox.
          entered << true
          gate.pop
        end
        m.call(names)
      end
      heartbeat = Thread.new { d.send(:heartbeat_names) }
      Timeout.timeout(5) { entered.pop }
      d.send(:release_queued, [inbox], :shutdown) # Finds nothing left to release.
      gate << :go
      Timeout.timeout(5) { heartbeat.join }
      expect(released.map { |r| [r[:reason], r[:count]] }).to eq [['stuck job', 2]]
      expect(jobs.drop(1)).to all(satisfy { |job| unlocked?(job) })
      expect(d.send(:in_flight)).to eq 1 # Only the stuck job.
    end
  end

  describe 'a queued job whose lock expired and was taken over before its thread picked it up' do
    it 'is neither run nor unlocked: the new owner keeps it' do
      Delayed::Worker.prefetch = 1
      Delayed::Worker.max_run_time = 60
      first, queued = gate_jobs(2)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, slot, job, reserved_at|
        # The queued job's lock dates from max_run_time ago: expired.
        m.call(slot, job, job.id == queued.id ? reserved_at - 60 : reserved_at)
      end
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && queued.locked_by }
      expect(first.locked_by).not_to be_nil
      # Another process reserved the expired job meanwhile.
      Delayed::Job.synchronize do
        queued.locked_by = 'other host pid:1'
        queued.locked_at = Delayed::Job.db_time_now
      end
      GateJob.release = true
      wait_until { log.map(&:last).grep(/waited in its queue until its lock expired/).any? }
      d.stop
      Timeout.timeout(10) { thread.join }
      expect(GateJob.finished).to eq [0]
      expect(queued.locked_by).to eq 'other host pid:1'
      expect(Delayed::Job.all).to eq [queued]
    end
  end

  describe 'exit_on_complete with prefetch' do
    before { ChainJob.runs = Concurrent::Array.new }

    [[2, false], [2, true]].each do |prefetch, dynamic|
      it "exits only once every link ran, leaving no job locked (prefetch #{prefetch}, dynamic #{dynamic})" do
        Delayed::Worker.prefetch = prefetch
        Delayed::Worker.prefetch_dynamic = dynamic
        seed = Random.new_seed
        srand(seed)
        10.times do |round|
          ChainJob.runs = Concurrent::Array.new
          chains = Array.new(4) { |c| [c, rand(2..5)] }
          chains.each { |c, length| Delayed::Job.enqueue(ChainJob.new(c, 0, length, 0.005)) }
          failing = Delayed::Job.enqueue(ErrorJob.new) # Rescheduled into the future: left behind.
          d = dispatcher(2)
          run_to_completion(d, 20)
          expected = chains.flat_map { |c, length| Array.new(length) { |link| [c, link] } }
          expect(ChainJob.runs).to match_array(expected), "round #{round}, seed #{seed}"
          expect(Delayed::Job.all).to eq([failing]), "round #{round}, seed #{seed}"
          expect([failing.attempts, failing.locked_by, failing.locked_at]).to eq [1, nil, nil]
          expect(ivar(d, :slot_jobs)).to be_empty
          Delayed::Job.delete_all
        end
      end
    end
  end

  describe 'the Rails reloader around jobs' do
    # Records run/complete; the completion can be held with a block.
    let(:wrapper_class) do
      Class.new do
        attr_reader :calls

        def initialize(&on_complete)
          @calls = Concurrent::Array.new
          @on_complete = on_complete
        end

        def wrap
          @calls << :run
          yield
        ensure
          @on_complete.call if @on_complete
          @calls << :complete
        end
      end
    end
    let(:executor) { wrapper_class.new }

    def with_app(reloader)
      app = Struct.new(:reloader, :executor).new(reloader, executor)
      allow(Rails).to receive(:application).and_return(app)
    end

    it 'lets a quit arriving while the reloader completes a finished job be, so the job is not released' do
      skip 'needs interrupt masking' unless Delayed::Dispatcher.interrupt_masking?
      completing = Queue.new
      saw_interrupt = Concurrent::AtomicBoolean.new(false)
      reloader = wrapper_class.new do
        completing << true
        # Holds the completion until the quit's interrupt is pending here.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.01 until Thread.pending_interrupt? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        saw_interrupt.value = Thread.pending_interrupt?
      end
      with_app(reloader)
      job = Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      thread = run_in_thread(d)
      Timeout.timeout(5) { completing.pop }
      d.quit
      Timeout.timeout(10) { thread.join }
      expect(saw_interrupt).to be_true
      expect(SimpleJob.runs).to eq 1
      expect(Delayed::Job.all).not_to include(job)
      expect(reloader.calls).to eq [:run, :complete]
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
    end

    it 'completes the reloader of a job interrupted by quit, and releases the job' do
      reloader = wrapper_class.new
      with_app(reloader)
      job, = gate_jobs(1)
      d = dispatcher(1)
      thread = run_in_thread(d)
      Timeout.timeout(5) { GateJob.started.pop }
      d.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [0]
      expect(reloader.calls).to eq [:run, :complete]
      expect(unlocked?(job)).to be true
    end
  end
end
