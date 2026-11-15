require 'helper'

describe Delayed::Dispatcher do
  let(:thread_count) { 4 }
  let(:dispatcher) { described_class.new(:threads => thread_count, :sleep_delay => 0.1) }

  before do
    Delayed::Job.delete_all
    ConcurrencyJob.reset
    Delayed::Worker.exit_on_complete = true
  end

  def enqueue_jobs(count)
    count.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
  end

  describe '#initialize' do
    it 'builds a single unindexed worker by default' do
      dispatcher = described_class.new
      expect(dispatcher.thread_count).to eq 1
      expect(dispatcher.workers.first.thread_index).to be_nil
      expect(dispatcher.workers.first.dispatcher).to eq dispatcher
    end

    it 'runs the given workers' do
      worker = Delayed::Worker.new
      expect(described_class.new(:workers => [worker]).workers).to eq [worker]
    end

    it 'builds one worker per thread with distinct names' do
      dispatcher.name_prefix = 'delayed_job.1 '
      names = dispatcher.workers.map(&:name)
      expect(names.uniq.size).to eq thread_count
      expect(names).to all(start_with('delayed_job.1 '))
      expect(names.last).to end_with('thread:3')
    end

    it 'rejects a thread count below 1' do
      expect { described_class.new(:threads => 0) }.to raise_error(ArgumentError)
      expect { described_class.new(:threads => -2) }.to raise_error(ArgumentError, 'threads must be 1 or greater')
    end

    it 'builds a single unindexed worker for threads: nil, as the launchers do' do
      dispatcher = described_class.new(:threads => nil)
      expect(dispatcher.thread_count).to eq 1
      expect(dispatcher.workers.first.thread_index).to be_nil
      expect(Delayed::Launcher::Forking.new({}).send(:threads, :threads => nil)).to eq dispatcher.thread_count
    end

    it 'accepts a thread count given as a string, e.g. from an environment variable' do
      expect(described_class.new(:threads => '3').thread_count).to eq 3
    end

    it 'rejects a thread count that is not a number' do
      expect { described_class.new(:threads => 'many') }.to raise_error(ArgumentError)
      expect { described_class.new(:threads => 1.5) }.not_to raise_error # Integer() truncates floats.
    end

    it 'builds one indexed worker per thread' do
      expect(described_class.new(:threads => 3).workers.map(&:thread_index)).to eq [0, 1, 2]
    end

    it 'runs jobs with threads: nil' do
      Delayed::Job.enqueue(SimpleJob.new)
      SimpleJob.runs = 0
      Timeout.timeout(5) { described_class.new(:threads => nil).tap { |d| allow(d).to receive(:say) }.run }
      expect(SimpleJob.runs).to eq 1
    end

    it 'can be built by a launcher with threads: nil' do
      launcher = Delayed::Launcher::Forking.new(:threads => nil)
      allow(launcher).to receive(:setup_logger)
      allow(launcher).to receive(:trap_signals)
      expect(Delayed::Dispatcher).to receive(:new).and_wrap_original do |m, options|
        m.call(options).tap { |d| expect(d.thread_count).to eq 1 }.tap { |d| allow(d).to receive(:start) }
      end
      launcher.launch
    end
  end

  describe '#start' do
    it 'traps signals and runs' do
      expect(dispatcher).to receive(:trap_signals).ordered
      expect(dispatcher).to receive(:run).ordered
      dispatcher.start
    end
  end

  describe '#run' do
    context 'with a single thread' do
      let(:thread_count) { 1 }

      it 'runs every job, one at a time' do
        enqueue_jobs(5)
        Timeout.timeout(10) { dispatcher.run }
        expect(ConcurrencyJob.runs.size).to eq 5
        expect(ConcurrencyJob.max_running).to eq 1
        expect(Delayed::Job.count).to eq 0
      end
    end

    it 'does not install signal traps' do
      expect(dispatcher).not_to receive(:trap)
      Timeout.timeout(5) { dispatcher.run }
    end

    it 'runs :loop callbacks around each poll, with the dispatcher' do
      polled = []
      dispatcher
      Delayed::Worker.lifecycle.around(:loop) do |p, &block|
        polled << p
        block.call(p)
      end
      enqueue_jobs(2)
      Timeout.timeout(5) { dispatcher.run }
      expect(polled).not_to be_empty
      expect(polled).to all(equal(dispatcher))
    end

    it 'logs throughput' do
      enqueue_jobs(3)
      allow(dispatcher).to receive(:say)
      expect(dispatcher).to receive(:say).with(/\A3 jobs processed at [\d.]+ j\/s, 0 failed\z/)
      Timeout.timeout(5) { dispatcher.run }
    end

    it 'runs every job exactly once, concurrently' do
      enqueue_jobs(20)
      Timeout.timeout(10) { dispatcher.run }

      expect(Delayed::Job.count).to eq 0
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...20).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
      expect(ConcurrencyJob.max_running).to be > 1
      expect(ConcurrencyJob.max_running).to be <= thread_count
    end

    it 'locks each job under the name of the thread that runs it' do
      enqueue_jobs(8)
      locked_by = Queue.new # Thread-safe: worker threads run in parallel (JRuby).
      allow_any_instance_of(Delayed::Worker).to receive(:perform_job).and_wrap_original do |m, job|
        locked_by << job.locked_by
        m.call(job)
      end
      Timeout.timeout(10) { dispatcher.run }
      lockers = Array.new(locked_by.size) { locked_by.pop }

      expect(lockers.size).to eq 8
      expect(lockers - dispatcher.workers.map(&:name)).to be_empty
      expect(lockers.uniq.size).to be > 1
    end

    it 'only reserves jobs for idle threads' do
      enqueue_jobs(6)
      batch_sizes = []
      allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, workers|
        expect(workers.size).to be <= thread_count
        m.call(workers).tap { |reserved| batch_sizes << reserved.size }
      end
      Timeout.timeout(10) { dispatcher.run }

      expect(batch_sizes.inject(:+)).to eq 6
      expect(batch_sizes.first).to eq thread_count
    end

    it 'queries the backend once per poll when idle' do
      Delayed::Worker.exit_on_complete = false
      polls = 0
      reserves = 0
      allow(Delayed::Job).to receive(:reserve).and_wrap_original do |m, *args|
        reserves += 1
        m.call(*args)
      end
      allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, workers|
        expect(workers.size).to eq thread_count
        dispatcher.stop if (polls += 1) == 3
        m.call(workers)
      end
      Timeout.timeout(5) { dispatcher.run }
      expect(polls).to eq 3
      expect(reserves).to eq 3
    end

    describe 'after a poll that reserved fewer jobs than idle threads' do
      let(:dispatcher) { described_class.new(:threads => thread_count, :sleep_delay => 5) }

      before { Delayed::Worker.exit_on_complete = false }

      # Stubs reserve_batch to reserve the given numbers of jobs on
      # successive polls (then none), recording when each poll happened.
      def reserve_in_polls(*counts)
        polls = []
        allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, workers|
          polls << [Process.clock_gettime(Process::CLOCK_MONOTONIC), workers.size]
          count = counts.shift || 0
          yield polls if block_given?
          m.call(workers.first(count))
        end
        polls
      end

      context 'with a backend whose partial batches may leave jobs' do
        before { allow(Delayed::Job).to receive(:partial_batch_may_leave_jobs?).and_return(true) }

        it 'polls again at once, as a batch reservation may have lost jobs to other processes' do
          enqueue_jobs(3)
          polls = reserve_in_polls(1, 2) { |p| dispatcher.stop if p.size == 3 }
          Timeout.timeout(3) { dispatcher.run }

          expect(polls.map(&:last)).to eq [4, 3, 1]
          expect(polls[1].first - polls[0].first).to be < 1
          expect(polls[2].first - polls[1].first).to be < 1
        end

        it 'still waits sleep_delay after a poll that reserved nothing' do
          polls = reserve_in_polls { |p| dispatcher.stop if p.size == 2 }
          thread = Thread.new { dispatcher.run }
          sleep 0.5
          expect(polls.size).to eq 1
          dispatcher.stop
          Timeout.timeout(3) { thread.join }
        end
      end

      context 'with a backend whose partial batches mean the queue ran dry (the default)' do
        it 'is the default' do
          expect(Delayed::Job.partial_batch_may_leave_jobs?).to be false
          expect(Delayed::Backend::Base::ClassMethods.instance_method(:partial_batch_may_leave_jobs?).owner).
            to eq Delayed::Backend::Base::ClassMethods
        end

        it 'does not poll again at once, saving a query each time the queue drains' do
          ConcurrencyJob.reset(1) # Busy for the whole check: no thread frees up.
          enqueue_jobs(1)
          polls = reserve_in_polls(1)
          thread = Thread.new { dispatcher.run }
          sleep 0.5
          expect(polls.size).to eq 1 # Not 2: no immediate empty re-poll.
          dispatcher.stop
          Timeout.timeout(3) { thread.join }
        end

        it 'still polls every sleep_delay for new jobs while some threads are busy' do
          d = described_class.new(:threads => 2, :sleep_delay => 0.1)
          allow(d).to receive(:say)
          ConcurrencyJob.reset(3) # The first job keeps one thread busy throughout.
          Delayed::Job.enqueue(ConcurrencyJob.new(1))
          thread = Thread.new { d.run }
          wait_until(3) { ConcurrencyJob.running == 1 }
          late = Delayed::Job.enqueue(ConcurrencyJob.new(2))
          # Picked up by the idle thread within sleep_delay, not after the 3s job.
          wait_until(1.5) { ConcurrencyJob.running == 2 }
          expect(ConcurrencyJob.runs[2]).to eq 1
          expect(late.reload.locked_by).not_to be_nil
          d.quit
          Timeout.timeout(10) { thread.join }
        end

        it 'polls again once a thread frees up' do
          ConcurrencyJob.reset(0.2)
          enqueue_jobs(2)
          polls = reserve_in_polls(1)
          thread = Thread.new { dispatcher.run }
          wait_until(3) { polls.size >= 2 }
          expect(polls[1].first - polls[0].first).to be >= 0.15 # Only after the job finished.
          dispatcher.stop
          Timeout.timeout(3) { thread.join }
        end
      end

      it 'does not poll again at once with a backend predating the hook' do
        allow(Delayed::Job).to receive(:respond_to?).and_call_original
        allow(Delayed::Job).to receive(:respond_to?).with(:partial_batch_may_leave_jobs?).and_return(false)
        ConcurrencyJob.reset(1)
        enqueue_jobs(1)
        polls = reserve_in_polls(1)
        thread = Thread.new { dispatcher.run }
        sleep 0.5
        expect(polls.size).to eq 1 # Treated as the default: no re-poll.
        dispatcher.stop
        Timeout.timeout(3) { thread.join }
      end

      it 'waits sleep_delay after a poll that reserved nothing' do
        polls = reserve_in_polls { |p| dispatcher.stop if p.size == 2 }
        thread = Thread.new { dispatcher.run }
        sleep 0.5
        expect(polls.size).to eq 1
        dispatcher.stop
        Timeout.timeout(3) { thread.join }
      end

      it 'waits for a thread to free up once all threads are busy' do
        enqueue_jobs(4)
        polls = reserve_in_polls(4)
        thread = Thread.new { dispatcher.run }
        wait_until(3) { Delayed::Job.all.empty? || polls.size > 1 }
        dispatcher.stop
        Timeout.timeout(3) { thread.join }
        expect(polls.first.last).to eq 4
      end
    end

    it 'lets running jobs finish when stopped' do
      ConcurrencyJob.reset(0.3)
      enqueue_jobs(8)
      Delayed::Worker.exit_on_complete = false
      thread = Thread.new { dispatcher.run }
      sleep 0.1 until ConcurrencyJob.running == thread_count
      dispatcher.stop
      Timeout.timeout(5) { thread.join }

      expect(ConcurrencyJob.running).to eq 0
      expect(ConcurrencyJob.runs.size).to eq thread_count
      expect(Delayed::Job.count).to eq 4
      expect(Delayed::Job.all.map(&:locked_by)).to all(be_nil)
    end

    it 'wakes up from the idle sleep promptly when stopped' do
      Delayed::Worker.exit_on_complete = false
      Delayed::Worker.sleep_delay = 30
      thread = Thread.new { dispatcher.run }
      sleep 0.2
      dispatcher.stop
      expect(Timeout.timeout(2) { thread.join }).to eq thread
    end

    it 'stops and re-raises when a thread dies' do
      enqueue_jobs(4)
      allow_any_instance_of(Delayed::Worker).to receive(:perform_job).and_raise(NoMemoryError, 'boom')
      expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(NoMemoryError, 'boom')
      expect(dispatcher.instance_variable_get(:@threads)).to all(satisfy { |t| !t.alive? })
    end

    it 'raises FatalBackendError after 10 reservation failures' do
      Delayed::Worker.exit_on_complete = false
      Delayed::Worker.sleep_delay = 0.01
      expect(Delayed::Job).to receive(:reserve).exactly(10).times.and_raise(StandardError)
      expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(Delayed::FatalBackendError)
    end

    describe 'a signal or exit during a reservation' do
      let(:reported) { Concurrent::Array.new }
      let(:messages) { Concurrent::Array.new }

      before do
        Delayed::Worker.exit_on_complete = false
        Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
        allow(dispatcher).to receive(:say) { |text, *| messages << text }
        allow(Delayed::Job).to receive(:recover_from)
      end

      after { Delayed::Worker.reset }

      [[SignalException, 'TERM'], [Interrupt, ''], [SystemExit, 'exit']].each do |klass, message|
        context "(#{klass})" do
          def raise_it(klass, message)
            klass == Interrupt ? raise(Interrupt) : raise(klass, message)
          end

          it 'propagates out of #run instead of counting as a failed reservation' do
            k = klass
            m = message
            allow(Delayed::Job).to receive(:reserve_batch) { raise_it(k, m) }
            expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(klass)
            expect(dispatcher.instance_variable_get(:@failed_reserve_count)).to eq 0
            expect(messages.grep(/Error while reserving job/)).to be_empty
            expect(Delayed::Job).not_to have_received(:recover_from)
          end

          it 'is not reported to on_thread_error' do
            k = klass
            m = message
            allow(Delayed::Job).to receive(:reserve_batch) { raise_it(k, m) }
            expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(klass)
            expect(reported).to be_empty
          end

          it 'is raised into running jobs too (signals only), and stops every thread' do
            k = klass
            m = message
            ConcurrencyJob.reset(2)
            # Poll again while the job runs (after the partial first batch).
            allow(Delayed::Job).to receive(:partial_batch_may_leave_jobs?).and_return(true)
            job = Delayed::Job.enqueue(ConcurrencyJob.new(1))
            calls = 0
            allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |orig, *args|
              calls += 1
              next orig.call(*args) if calls == 1
              sleep 0.01 until ConcurrencyJob.running == 1
              raise_it(k, m)
            end
            took = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expect { Timeout.timeout(10) { dispatcher.run } }.to raise_error(klass)
            took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - took
            expect(dispatcher.instance_variable_get(:@threads)).to all(satisfy { |t| !t.alive? })
            if klass <= SignalException
              expect(took).to be < 1.5 # Interrupted, not left to run its 2s.
              expect(Delayed::Job.all).to include job # Not completed.
            else
              expect(took).to be >= 1.5 # An exit lets the running job finish.
            end
          end
        end
      end

      it 'still treats other exceptions as failed reservations' do
        calls = 0
        allow(Delayed::Job).to receive(:reserve_batch) do
          raise NoMemoryError, 'odd' if (calls += 1) == 1
          []
        end
        Delayed::Worker.exit_on_complete = true
        Timeout.timeout(5) { dispatcher.run }
        expect(messages.grep(/Error while reserving job: odd/).size).to eq 1
        expect(reported.map { |_, info| info[:context] }).to eq ['Reservation']
      end
    end

    it 'runs :execute callbacks for every thread and clears their locks' do
      dispatcher # Worker.new resets the lifecycle, so build it first
      names = Queue.new # Thread-safe: the callbacks run on parallel threads (JRuby).
      expect(Delayed::Job).to receive(:clear_locks!).exactly(thread_count).times
      Delayed::Worker.lifecycle.around(:execute) do |w, &block|
        names << w.name
        block.call(w)
      end
      Timeout.timeout(5) { dispatcher.run }
      executed = Array.new(names.size) { names.pop }
      expect(executed).to match_array(dispatcher.workers.map(&:name))
    end
  end
end

describe Delayed::Backend::Base do
  describe '.reserve_batch' do
    let(:workers) { Array.new(3) { |i| Delayed::Worker.new.tap { |w| w.thread_index = i } } }

    before { Delayed::Job.delete_all }

    it 'locks a distinct job under each worker name' do
      3.times { Delayed::Job.enqueue(SimpleJob.new) }
      reserved = Delayed::Job.reserve_batch(workers)
      expect(reserved.map(&:first)).to eq workers
      expect(reserved.map(&:last).uniq.size).to eq 3
      reserved.each { |w, job| expect(job.locked_by).to eq w.name }
    end

    it 'stops at the first worker without a job' do
      Delayed::Job.enqueue(SimpleJob.new)
      expect(Delayed::Job).to receive(:reserve).twice.and_call_original
      expect(Delayed::Job.reserve_batch(workers).size).to eq 1
    end

    it 'returns already reserved jobs when a later reservation fails' do
      Delayed::Job.enqueue(SimpleJob.new)
      calls = 0
      allow(Delayed::Job).to receive(:reserve).and_wrap_original do |m, *args|
        (calls += 1) == 1 ? m.call(*args) : raise('db down')
      end
      expect(Delayed::Job.reserve_batch(workers).size).to eq 1
    end

    it 'raises when the first reservation fails' do
      allow(Delayed::Job).to receive(:reserve).and_raise('db down')
      expect { Delayed::Job.reserve_batch(workers) }.to raise_error('db down')
    end
  end
end
