require 'helper'
require_relative 'processes/helpers'

# Lock heartbeats (Worker.lock_heartbeat_interval / lock_timeout) and
# owner-guarded writes, on a real Active Record backend (an SQLite file).
describe 'Lock heartbeats' do
  include ProcessHelpers

  around do |example|
    Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
    example.run
  ensure
    Delayed::Worker.reset
    Delayed::Worker.backend = :test
  end

  describe Delayed::Backend::SqliteFile::Job do
    it_behaves_like 'a delayed_job backend supporting lock heartbeats'
  end

  describe 'settings' do
    it 'is off by default, with a 5 minute lock timeout' do
      expect(Delayed::Worker.lock_heartbeat_interval).to be_nil
      expect(Delayed::Worker.lock_timeout).to eq 5.minutes
      expect(Delayed::Worker.lock_heartbeats?).to be false
    end

    it 'is set by Worker.new options' do
      Delayed::Worker.new(:lock_heartbeat_interval => 10, :lock_timeout => 45)
      expect([Delayed::Worker.lock_heartbeat_interval, Delayed::Worker.lock_timeout]).to eq [10, 45]
    end

    describe '.lock_expiry' do
      it 'is max_run_time without heartbeats' do
        expect(Delayed::Worker.lock_expiry).to eq Delayed::Worker.max_run_time
      end

      it 'is lock_timeout with heartbeats' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 45
        expect(Delayed::Worker.lock_heartbeats?).to be true
        expect(Delayed::Worker.lock_expiry).to eq 45
      end

      it 'stays max_run_time when the backend does not support heartbeats' do
        Delayed::Worker.backend = :test
        Delayed::Worker.lock_heartbeat_interval = 10
        expect(Delayed::Worker.lock_heartbeats?).to be false
        expect(Delayed::Worker.lock_expiry).to eq Delayed::Worker.max_run_time
      end
    end

    describe '.validate_lock_heartbeats!' do
      it 'accepts no heartbeats' do
        expect { Delayed::Worker.validate_lock_heartbeats! }.not_to raise_error
      end

      it 'accepts a lock timeout of at least twice the interval' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 20
        expect { Delayed::Worker.validate_lock_heartbeats! }.not_to raise_error
      end

      it 'rejects a lock timeout shorter than twice the interval' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 19
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError, /at least twice/)
      end

      it 'rejects a missing lock timeout' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = nil
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError)
      end

      it 'rejects a non-positive interval' do
        Delayed::Worker.lock_heartbeat_interval = 0
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError, /greater than 0/)
      end
    end
  end

  describe 'the default backend hooks' do
    it 'do not support heartbeats' do
      expect(Delayed::Backend::Test::Job.lock_heartbeats?).to be false
      expect { Delayed::Backend::Test::Job.touch_locks(['w']) }.to raise_error(NotImplementedError)
    end
  end

  describe Delayed::Dispatcher do
    let(:dispatcher) { described_class.new(:threads => 2, :sleep_delay => 0.05) }
    let(:messages) { Concurrent::Array.new }
    let(:job_class) { Delayed::Backend::SqliteFile::Job }

    before do
      SimpleJob.runs = 0
      capture_say(messages, dispatcher)
      Delayed::Worker.lock_heartbeat_interval = 0.1
      Delayed::Worker.lock_timeout = 0.5
    end

    def run_dispatcher
      @dispatcher_thread = Thread.new { dispatcher.run }.tap { |t| t.report_on_exception = false }
    end

    # A failed example must not leave its dispatcher polling in later ones.
    after do
      next unless @dispatcher_thread && @dispatcher_thread.alive?
      dispatcher.quit
      @dispatcher_thread.join(10) rescue nil
      @dispatcher_thread.kill
    end

    it 'refreshes the locks of running jobs while they run' do
      job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 1.2))
      thread = run_dispatcher
      wait_for { job_class.find(job.id).locked_by }
      first = job_class.find(job.id).locked_at
      sleep 0.6 # longer than lock_timeout
      refreshed = job_class.find(job.id).locked_at
      dispatcher.stop
      Timeout.timeout(5) { thread.join }

      expect(refreshed).to be > first
      expect(job_class.where(:id => job.id)).to be_empty
    end

    it 'refreshes the locks of every worker thread in one call per heartbeat' do
      names = []
      allow(job_class).to receive(:touch_locks) { |n|
        names << n
        0
      }
      thread = run_dispatcher
      sleep 0.35
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(names.size).to be_between(1, 4) # One per 0.1s interval at most, however slow the machine.
      expect(names).to all(eq(dispatcher.workers.map(&:name)))
    end

    it 'reserves jobs whose locks are older than lock_timeout' do
      stale = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'gone', :locked_at => job_class.db_time_now - 1)
      SimpleJob.runs = 0
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(job_class.where(:id => stale.id)).to be_empty
      expect(SimpleJob.runs).to eq 1
    end

    it 'does not reserve jobs whose locks are fresh' do
      fresh = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'alive', :locked_at => job_class.db_time_now)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(job_class.find(fresh.id).locked_by).to eq 'alive'
    end

    it 'logs heartbeat errors and keeps beating' do
      calls = 0
      allow(job_class).to receive(:touch_locks) do
        calls += 1
        raise IOError, 'db hiccup' if calls == 1
        0
      end
      thread = run_dispatcher
      sleep 0.35
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(calls).to be >= 2
      expect(messages).to include(['error', 'Error while refreshing job locks: IOError: db hiccup'])
    end

    describe 'errors ending the heartbeat' do
      let(:reported) { Concurrent::Array.new }

      before { Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] } }

      def run_briefly(seconds = 0.35)
        thread = run_dispatcher
        sleep seconds
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
      end

      def stopped_messages
        messages.select { |_, text| text.start_with?('Lock heartbeat stopped') }
      end

      def retry_messages
        messages.select { |_, text| text.start_with?('Lock heartbeat failed') }
      end

      it 'reports a non-StandardError, logs it, and beats again at the next interval' do
        calls = 0
        allow(job_class).to receive(:touch_locks) do
          calls += 1
          raise NoMemoryError, 'failed to allocate memory' if calls == 1
          0
        end
        run_briefly(0.45)
        expect(calls).to be >= 2
        expect(stopped_messages).to be_empty
        level, text = retry_messages.first
        expect(level).to eq 'error'
        expect(text).to eq 'Lock heartbeat failed with NoMemoryError: failed to allocate memory; retrying in 0.1s (1/5)'
        expect(reported.size).to eq 1
        error, info = reported.first
        expect(error).to be_a NoMemoryError
        expect(info).to eq(:context => 'Lock heartbeat', :dispatcher => dispatcher.name, :worker => nil)
      end

      it 'keeps the locks of running jobs alive across such an error' do
        calls = 0
        allow(job_class).to receive(:touch_locks).and_wrap_original do |m, names|
          calls += 1
          raise NoMemoryError, 'oom' if calls == 2
          m.call(names)
        end
        job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 1.2))
        thread = run_dispatcher
        wait_for { job_class.find(job.id).locked_by }
        owner = job_class.find(job.id).locked_by
        sleep 0.8 # Past lock_timeout (0.5s), with one failed heartbeat.
        expect(job_class.find(job.id).locked_by).to eq owner
        expect(job_class.reserve(Delayed::Worker.new.tap { |w| w.name = 'other process' }, 0.5)).to be_nil
        wait_for { job_class.where(:id => job.id).empty? }
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
        expect(retry_messages.size).to eq 1
      end

      it "gives up after #{Delayed::Dispatcher::MAX_HEARTBEAT_CRASHES} consecutive failures, leaving the dispatcher running" do
        calls = 0
        allow(job_class).to receive(:touch_locks) do
          calls += 1
          raise NoMemoryError, 'oom'
        end
        thread = run_dispatcher
        wait_for(5) { (h = dispatcher.instance_variable_get(:@heartbeat)) && !h.alive? }
        sleep 0.3
        expect(calls).to eq Delayed::Dispatcher::MAX_HEARTBEAT_CRASHES
        expect(thread).to be_alive
        expect(retry_messages.size).to eq Delayed::Dispatcher::MAX_HEARTBEAT_CRASHES - 1
        expect(stopped_messages.size).to eq 1
        level, text = stopped_messages.first
        expect(level).to eq 'error'
        expect(text).to eq 'Lock heartbeat stopped after 5 consecutive failures (last: NoMemoryError: oom); the locks of ' \
                           'running jobs are no longer refreshed and expire after lock_timeout (0.5s)'
        expect(reported.size).to eq Delayed::Dispatcher::MAX_HEARTBEAT_CRASHES
        dispatcher.stop
        Timeout.timeout(5) { thread.join } # Stopping joins the finished heartbeat fine.
      end

      it 'counts only consecutive failures' do
        calls = 0
        allow(job_class).to receive(:touch_locks) do
          calls += 1
          raise NoMemoryError, 'oom' unless (calls % 4).zero? # 3 failures, then a success, repeatedly.
          0
        end
        run_briefly(1.2)
        expect(calls).to be > Delayed::Dispatcher::MAX_HEARTBEAT_CRASHES
        expect(stopped_messages).to be_empty
      end

      it 'is ended at once by a signal' do
        allow(job_class).to receive(:touch_locks).and_raise(SignalException, 'TERM')
        thread = run_dispatcher
        wait_for(5) { (h = dispatcher.instance_variable_get(:@heartbeat)) && !h.alive? }
        expect(job_class).to have_received(:touch_locks).once
        expect(retry_messages).to be_empty
        expect(reported).to be_empty
        dispatcher.stop
        expect { Timeout.timeout(5) { thread.join } }.to raise_error(SignalException)
      end

      it 'publishes a thread_error event' do
        events = payloads_of(:thread_error)
        calls = 0
        allow(job_class).to receive(:touch_locks) {
          raise ScriptError, 'broken' if (calls += 1) == 1
          0
        }
        run_briefly
        expect(events.map { |p| p[:context] }).to eq ['Lock heartbeat']
      end

      it 'keeps beating after a StandardError while choosing which locks to refresh' do
        calls = 0
        allow(dispatcher).to receive(:heartbeat_names).and_wrap_original do |m|
          calls += 1
          raise ArgumentError, "a job's max_run_time raised" if calls == 1
          m.call
        end
        touched = 0
        allow(job_class).to receive(:touch_locks) {
          touched += 1
          0
        }
        run_briefly
        expect(calls).to be >= 2
        expect(touched).to be >= 1
        expect(stopped_messages).to be_empty
        expect(messages).to include(['error', "Error while refreshing job locks: ArgumentError: a job's max_run_time raised"])
        expect(reported.map { |_, info| info[:context] }.uniq).to eq ['Lock heartbeat']
      end

      it 'logs nothing more when a StandardError is raised refreshing locks' do
        allow(job_class).to receive(:touch_locks).and_raise(IOError, 'db hiccup')
        run_briefly
        expect(stopped_messages).to be_empty
        expect(dispatcher.instance_variable_get(:@heartbeat)).not_to be_alive # Joined on stop.
      end

      it 'is not reported when the heartbeat is stopped normally' do
        run_briefly
        expect(stopped_messages).to be_empty
        expect(reported).to be_empty
      end
    end

    describe 'stopping while a lock refresh is stuck' do
      it 'stops after HEARTBEAT_STOP_TIMEOUT instead of waiting for it forever' do
        stub_const('Delayed::Dispatcher::HEARTBEAT_STOP_TIMEOUT', 0.3)
        stuck = Queue.new
        release = Queue.new
        allow(job_class).to receive(:touch_locks) do
          stuck << true
          release.pop # A database call that hangs.
          0
        end
        thread = run_dispatcher
        Timeout.timeout(5) { stuck.pop }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        dispatcher.stop
        expect(Timeout.timeout(5) { thread.join }).to eq thread
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.25, 3)
        expect(messages).to include(['warn', 'Lock heartbeat did not stop within 0.3s (a lock refresh may be stuck); not waiting for it'])
        heartbeat = dispatcher.instance_variable_get(:@heartbeat)
        expect(heartbeat).to be_alive
        release << true # The refresh returns: the heartbeat then stops.
        expect(heartbeat.join(5)).to eq heartbeat
        expect(job_class).to have_received(:touch_locks).once
      end

      it 'does not warn when the heartbeat stops in time' do
        thread = run_dispatcher
        sleep 0.15
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
        expect(messages.map(&:last).grep(/did not stop within/)).to be_empty
      end
    end

    it 'stops the heartbeat thread when it stops' do
      thread = run_dispatcher
      sleep 0.15
      heartbeat = dispatcher.instance_variable_get(:@heartbeat)
      expect(heartbeat).to be_alive
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(heartbeat).not_to be_alive
    end

    it 'does not start a heartbeat when heartbeats are off' do
      Delayed::Worker.lock_heartbeat_interval = nil
      expect(job_class).not_to receive(:touch_locks)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(dispatcher.instance_variable_get(:@heartbeat)).to be_nil
    end

    it 'warns and runs without heartbeats when the backend does not support them' do
      allow(job_class).to receive(:lock_heartbeats?).and_return(false)
      expect(job_class).not_to receive(:touch_locks)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(messages.map(&:last).grep(/does not support them; locks expire after max_run_time/).size).to eq 1
    end

    it 'refuses to run with invalid heartbeat settings' do
      Delayed::Worker.lock_timeout = 0.1
      expect { dispatcher.run }.to raise_error(ArgumentError, /at least twice/)
    end

    it 'reserves with the lock timeout as the lock expiry' do
      expect(job_class).to receive(:reserve_batch).with(anything, 0.5).at_least(:once).and_return([])
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
    end

    describe 'jobs running past their max_run_time' do
      let(:worker) { dispatcher.workers.first }
      let(:other) { dispatcher.workers.last }

      before do
        capture_say(messages, *dispatcher.workers)
      end

      # Records the job as Worker#run does, started `seconds_ago`.
      def job_running(worker, job, seconds_ago)
        dispatcher.job_timed(worker, job, worker.max_run_time(job).to_i)
        dispatcher.instance_variable_get(:@jobs_started)[worker][1] -= seconds_ago
      end

      def job_with_max_run_time(limit)
        job_class.new(:payload_object => StuckJob.new(0, limit))
      end

      def overrun_messages
        messages.map(&:last).grep(/longer than its max_run_time/)
      end

      describe '#heartbeat_names' do
        it 'is every worker when no job runs' do
          expect(dispatcher.send(:heartbeat_names)).to eq dispatcher.workers.map(&:name)
        end

        it 'keeps workers whose job runs within max_run_time' do
          job_running(worker, job_with_max_run_time(nil), 60)
          expect(dispatcher.send(:heartbeat_names)).to eq dispatcher.workers.map(&:name)
        end

        it 'leaves out a worker whose job runs past Worker.max_run_time' do
          Delayed::Worker.max_run_time = 10
          job_running(worker, job_with_max_run_time(nil), 11)
          expect(dispatcher.send(:heartbeat_names)).to eq [other.name]
        end

        it 'names the job in its log message as job_say does' do
          job = job_class.create!(:payload_object => StuckJob.new(0, 1), :queue => 'mail')
          job_running(worker, job, 2)
          dispatcher.send(:heartbeat_names)
          expect(overrun_messages.first).to start_with "Job StuckJob (id=#{job.id}) (queue=mail) has run for longer"
        end

        it "uses the job's own max_run_time" do
          job_running(worker, job_with_max_run_time(5), 6)
          job_running(other, job_with_max_run_time(5), 4)
          expect(dispatcher.send(:heartbeat_names)).to eq [other.name]
        end

        it 'is empty when every worker overran' do
          job_running(worker, job_with_max_run_time(1), 2)
          job_running(other, job_with_max_run_time(1), 2)
          expect(dispatcher.send(:heartbeat_names)).to eq []
        end

        it 'treats a max_run_time below one second as no limit, as Worker#run does' do
          job_running(worker, job_with_max_run_time(0.5), 60)
          expect(dispatcher.send(:heartbeat_names)).to eq dispatcher.workers.map(&:name)
        end

        it 'logs an error once per overrunning job' do
          job = job_with_max_run_time(1)
          job_running(worker, job, 2)
          3.times { dispatcher.send(:heartbeat_names) }
          expect(overrun_messages.size).to eq 1
          expect(messages.find { |_, text| text =~ /longer than its max_run_time/ }.first).to eq 'error'
          expect(overrun_messages.first).to include 'max_run_time (1s)', 'lock_timeout (0.5s)'
        end

        it 'never loads the job from the heartbeat thread to publish job_stuck' do
          job = job_with_max_run_time(1)
          job_running(worker, job, 2)
          expect(job).not_to receive(:payload_object)
          expect(job).not_to receive(:name)
          dispatcher.send(:heartbeat_names)
        end

        it 'publishes job_stuck once per stuck job' do
          events = payloads_of(:job_stuck)
          job = job_with_max_run_time(1)
          job_running(worker, job, 2)
          3.times { dispatcher.send(:heartbeat_names) }
          expect(events).to eq [{:job => job, :job_name => "Job StuckJob (id=#{job.id})", :worker => worker.name,
                                 :max_run_time => 1, :lock_timeout => 0.5}]
        end

        it 'logs again for the next job that overruns on the same worker' do
          job_running(worker, job_with_max_run_time(1), 2)
          dispatcher.send(:heartbeat_names)
          job_running(worker, job_with_max_run_time(1), 2)
          dispatcher.send(:heartbeat_names)
          expect(overrun_messages.size).to eq 2
        end

        it 'never calls into running jobs (it runs on the heartbeat thread)' do
          job = job_with_max_run_time(1)
          job_running(worker, job, 2)
          expect(worker).not_to receive(:max_run_time)
          expect(job).not_to receive(:max_run_time)
          expect(job).not_to receive(:payload_object)
          dispatcher.send(:heartbeat_names)
        end
      end

      describe '#job_timed' do
        it 'records the job, when it started, its limit and its log label' do
          job = job_class.create!(:payload_object => StuckJob.new(0, 3), :queue => 'mail')
          dispatcher.job_timed(worker, job, 3)
          recorded, started, limit, label = dispatcher.instance_variable_get(:@jobs_started)[worker]
          expect(recorded).to equal job
          expect(started).to be_within(1).of(dispatcher.send(:monotonic_now))
          expect(limit).to eq 3
          expect(label).to eq "Job StuckJob (id=#{job.id}) (queue=mail)"
        end

        it 'records no limit under one second, as Worker#run sets no timeout then' do
          dispatcher.job_timed(worker, job_with_max_run_time(0), 0)
          expect(dispatcher.instance_variable_get(:@jobs_started)[worker][2]).to be_nil
        end

        it "is called by Worker#run with the job's max_run_time in whole seconds" do
          expect(dispatcher).to receive(:job_timed).with(worker, kind_of(job_class), 7)
          job_class.create!(:payload_object => StuckJob.new(0, 7.9))
          expect(dispatcher.work_off(1, worker)).to eq [1, 0]
        end

        it 'is called with Worker.max_run_time when the job has none' do
          Delayed::Worker.max_run_time = 42
          expect(dispatcher).to receive(:job_timed).with(worker, kind_of(job_class), 42)
          job_class.create!(:payload_object => SimpleJob.new)
          dispatcher.work_off(1, worker)
        end

        it 'is not needed by a Worker running without a dispatcher' do
          worker = Delayed::Worker.allocate.tap { |w| w.instance_variable_set(:@quiet, true) }
          allow(worker).to receive(:say)
          job = job_class.create!(:payload_object => SimpleJob.new)
          expect(worker.run(job)).to be true
        end

        it 'works the limit out once, on the thread that runs the job' do
          threads = []
          allow(worker).to(receive(:max_run_time).and_wrap_original do |m, job|
            threads << Thread.current
            m.call(job)
          end)
          allow_any_instance_of(SimpleJob).to receive(:perform) { 3.times { dispatcher.send(:heartbeat_names) } }
          job_class.create!(:payload_object => SimpleJob.new)
          expect(dispatcher.work_off(1, worker)).to eq [1, 0]
          expect(threads).to eq [Thread.current]
        end

        it 'deserializes the job inside its :perform callbacks, as before' do
          dispatcher # Worker.new resets the lifecycle.
          Delayed::Worker.lifecycle.around(:perform) do |w, j, &block|
            Thread.current[:dj_in_perform] = true
            block.call(w, j)
          ensure
            Thread.current[:dj_in_perform] = nil
          end
          loads = []
          allow_any_instance_of(job_class).to receive(:payload_object).and_wrap_original do |m|
            loads << !!Thread.current[:dj_in_perform]
            m.call
          end
          job_class.create!(:payload_object => SimpleJob.new)
          expect(dispatcher.work_off(1, worker)).to eq [1, 0]
          expect(loads).not_to be_empty
          expect(loads).to all(be true)
        end
      end

      it 'fails a job whose max_run_time raises, as before, while the heartbeat refreshes every lock' do
        touched = Queue.new
        allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, names|
          touched << names
          m.call(names)
        end)
        allow_any_instance_of(StuckJob).to receive(:max_run_time).and_raise(ArgumentError, 'broken job')
        broken = job_class.create!(:payload_object => StuckJob.new(0, 1))
        long = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 0.5))
        # Poll often, so a poll that reserved only the broken job is followed
        # by another soon; and allow a slow CI machine time to run both.
        Delayed::Worker.sleep_delay = 0.05
        thread = run_dispatcher
        wait_for(15) { job_class.where(:id => long.id).empty? }
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
        expect(job_class.find(broken.id).last_error).to match(/broken job/)
        names = Array.new(touched.size) { touched.pop }
        expect(names).not_to be_empty
        expect(names).to all(eq(dispatcher.workers.map(&:name)))
        expect(messages.map(&:last).grep(/Error while refreshing job locks/)).to be_empty
      end

      describe '#untrack_job_after' do
        it 'returns the result of the block' do
          expect(dispatcher.send(:untrack_job_after, worker) { :result }).to eq :result
        end

        it 'forgets the job and its overrun report once the block is done' do
          job = job_with_max_run_time(1)
          dispatcher.send(:untrack_job_after, worker) do
            job_running(worker, job, 2)
            dispatcher.send(:heartbeat_names)
          end
          expect(dispatcher.instance_variable_get(:@jobs_started)).to be_empty
        end

        it 'forgets them even when the job raises' do
          job = job_with_max_run_time(1)
          expect do
            dispatcher.send(:untrack_job_after, worker) do
              job_running(worker, job, 2)
              dispatcher.send(:heartbeat_names)
              raise Delayed::ShutdownInterrupt
            end
          end.to raise_error(Delayed::ShutdownInterrupt)
          expect(dispatcher.instance_variable_get(:@jobs_started)).to be_empty
        end

        it 'has jobs run by worker threads timed while they run' do
          seen = Queue.new
          d = dispatcher
          allow_any_instance_of(SimpleJob).to receive(:perform) { seen << d.instance_variable_get(:@jobs_started).keys }
          job_class.create!(:payload_object => SimpleJob.new)
          Delayed::Worker.exit_on_complete = true
          Timeout.timeout(5) { dispatcher.run }
          keys = seen.pop
          expect(keys.size).to eq 1
          expect(dispatcher.workers).to include(*keys)
          expect(dispatcher.instance_variable_get(:@jobs_started)).to be_empty
        end

        it 'has jobs run inline by #work_off timed while they run' do
          seen = nil
          d = dispatcher
          allow_any_instance_of(SimpleJob).to receive(:perform) { seen = d.instance_variable_get(:@jobs_started).keys }
          job_class.create!(:payload_object => SimpleJob.new)
          expect(dispatcher.work_off(1, worker)).to eq [1, 0]
          expect(seen).to eq [worker]
          expect(dispatcher.instance_variable_get(:@jobs_started)).to be_empty
        end
      end

      it 'stops refreshing the lock of a job stuck past its max_run_time, so another worker can take it over' do
        touched = Queue.new
        allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, names|
          touched << names
          m.call(names)
        end)
        runs = Queue.new
        # Stuck (2.5s, past its 1s max_run_time) on its first run only.
        allow_any_instance_of(StuckJob).to receive(:perform).and_wrap_original do |m|
          runs << Thread.current
          runs.size == 1 ? m.call : nil
        end
        job = job_class.create!(:payload_object => StuckJob.new(2.5, 1))
        thread = run_dispatcher
        wait_for { job_class.find(job.id).locked_by }
        owner = job_class.find(job.id).locked_by
        sleep 0.8
        # Past lock_timeout (0.5s), but refreshed: nobody else can take it.
        expect(job_class.find(job.id).locked_by).to eq owner
        expect(job_class.reserve(Delayed::Worker.new.tap { |w| w.name = 'other process' }, 0.5)).to be_nil

        # After max_run_time, the lock isn't refreshed; 0.5s later the idle
        # thread takes the job over and runs it, while the stuck run goes on.
        wait_for(4) { runs.size == 2 }
        wait_for { job_class.where(:id => job.id).empty? }
        expect(thread).to be_alive # The stuck run hasn't finished yet.

        Timeout.timeout(5) { sleep 0.05 until messages.map(&:last).grep(/another worker reserved it/).any? }
        dispatcher.stop
        Timeout.timeout(5) { thread.join }

        first, second = Array.new(2) { runs.pop }
        expect(second).not_to eq first # Taken over by the other thread.
        names = Array.new(touched.size) { touched.pop }
        expect(names.first).to include owner
        expect(names.select { |n| n.include?(owner) }.size).to be < names.size
        expect(names.reject { |n| n.include?(owner) }).to all(satisfy { |n| !n.empty? })
        expect(overrun_messages.size).to eq 1
        # The stuck run's late outcome was discarded, not written over the takeover's.
        expect(messages.map(&:last).grep(/was finished here, but its lock expired/).size).to eq 1
        expect(job_class.where(:id => job.id)).to be_empty
      end

      it 'keeps refreshing the lock of a long job within its max_run_time' do
        job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 1.0))
        allow_any_instance_of(ProcessJobs::SleepJob).to receive(:max_run_time).and_return(5)
        thread = run_dispatcher
        wait_for { job_class.find(job.id).locked_by }
        owner = job_class.find(job.id).locked_by
        sleep 0.8
        expect(job_class.find(job.id).locked_by).to eq owner
        expect(job_class.find(job.id).locked_at).to be > job_class.db_time_now - 0.5
        wait_for { job_class.where(:id => job.id).empty? }
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
        expect(overrun_messages).to be_empty
      end
    end

    describe '#work_off' do
      it 'refreshes locks while running jobs inline' do
        job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('inline', 0.5))
        touched = []
        allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, n|
          touched << n
          m.call(n)
        end)
        expect(dispatcher.work_off(1, dispatcher.workers.first)).to eq [1, 0]
        expect(touched).not_to be_empty
        expect(job_class.where(:id => job.id)).to be_empty
        expect(dispatcher.instance_variable_get(:@heartbeat)).not_to be_alive
      end
    end
  end

  describe 'a worker whose lock was taken over' do
    let(:job_class) { Delayed::Backend::SqliteFile::Job }
    let(:stale) { Delayed::Worker.new.tap { |w| w.name = 'stale' } }
    let(:logged) { Concurrent::Array.new }

    before do
      SimpleJob.runs = 0
      allow(stale).to receive(:say) { |text, *| logged << text }
    end

    it 'logs that it left the job to the new owner' do
      job = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'stale', :locked_at => job_class.db_time_now)
      job_class.find(job.id).lock_exclusively!(0, 'new owner')
      stale.run(job)
      expect(logged.grep(/was finished here, but its lock expired and another worker reserved it; leaving the job to that worker/)).not_to be_empty
      expect(job_class.find(job.id).locked_by).to eq 'new owner'
    end

    it 'writes unlocked jobs without a guard, as before' do
      job = job_class.create!(:payload_object => SimpleJob.new)
      expect(job).not_to receive(:destroy_if_locked_by)
      stale.run(job)
      expect(job_class.where(:id => job.id)).to be_empty
    end

    it "recovering a dead worker's job does not touch it once another worker took it" do
      job = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'dead', :locked_at => job_class.db_time_now - 3600)
      allow(job_class).to receive(:locked_jobs).and_wrap_original do |m, name|
        m.call(name).tap { job_class.find(job.id).lock_exclusively!(0, 'new owner') }
      end
      status = double(:signaled? => true, :termsig => 9)
      Delayed::Worker.recover_jobs_of(['dead'], Delayed::ProcessExitError.new('dj.1', 1, status))
      saved = job_class.find(job.id)
      expect([saved.locked_by, saved.attempts]).to eq ['new owner', 0]
    end
  end
end
