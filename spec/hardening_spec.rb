require 'helper'

# Robustness of the dispatcher's bookkeeping under unlucky timing.
describe 'Dispatcher robustness' do
  let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2) }

  before { silence_say(*and_workers(dispatcher)) }

  describe 'an overrun report racing the end of its job' do
    it 'does not mark the worker, which would leave it idle forever' do
      worker = dispatcher.workers.first
      job = Delayed::Job.enqueue(SimpleJob.new)
      dispatcher.job_timed(worker, job, 1)
      dispatcher.send(:untrack_job_after, worker) { nil } # The job ends before the report.
      dispatcher.send(:report_overrun, worker, job, 1, 'Job')
      expect(dispatcher.send(:synchronize) { dispatcher.send(:overrun_workers) }).to be_empty
      expect(dispatcher.send(:snapshot).first).to include(worker)
    end

    it "does not mark the worker's next job either" do
      worker = dispatcher.workers.first
      stale = Delayed::Job.enqueue(SimpleJob.new)
      dispatcher.job_timed(worker, stale, 1)
      dispatcher.send(:untrack_job_after, worker) { nil }
      dispatcher.job_timed(worker, Delayed::Job.enqueue(SimpleJob.new), 60) # The next job starts.
      dispatcher.send(:report_overrun, worker, stale, 1, 'Job')
      expect(dispatcher.send(:snapshot).first).to include(worker)
    end

    it 'marks a worker whose overrun job still runs, until it ends' do
      worker = dispatcher.workers.first
      job = Delayed::Job.enqueue(SimpleJob.new)
      dispatcher.job_timed(worker, job, 1)
      dispatcher.send(:report_overrun, worker, job, 1, 'Job')
      expect(dispatcher.send(:snapshot).first).not_to include(worker)
      dispatcher.send(:untrack_job_after, worker) { nil }
      expect(dispatcher.send(:snapshot).first).to include(worker)
    end
  end

  describe 'a worker thread that fails to start' do
    it 'still stops the threads already started' do
      calls = 0
      allow(dispatcher).to receive(:spawn_thread).and_wrap_original do |m, *args, &block|
        raise ThreadError, "can't create Thread" if (calls += 1) == 2
        m.call(*args, &block)
      end
      expect { Timeout.timeout(10) { dispatcher.run } }.to raise_error(ThreadError)
      threads = dispatcher.instance_variable_get(:@threads)
      expect(threads.size).to eq 1
      expect(threads).to all(satisfy { |t| !t.alive? })
    end
  end

  describe 'a lock heartbeat left behind by an earlier run' do
    it 'stops on its own control, whatever a later run set up' do
      stale = Delayed::Dispatcher::HeartbeatControl.new(Mutex.new, ConditionVariable.new, true)
      dispatcher.instance_variable_set(:@heartbeat_control,
                                       Delayed::Dispatcher::HeartbeatControl.new(Mutex.new, ConditionVariable.new, false))
      expect(dispatcher).not_to receive(:heartbeat)
      expect { Timeout.timeout(2) { dispatcher.send(:lock_heartbeat_loop, 0.01, stale) } }.not_to raise_error
    end
  end

  describe 'Backend::Base.reserve_batch failing part way' do
    it 'returns the jobs already reserved, and reports the error' do
      reported = []
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error.message, info[:context]] }
      2.times { Delayed::Job.enqueue(SimpleJob.new) }
      workers = Array.new(3) { |i| Delayed::Worker.named("w#{i}") }
      calls = 0
      allow(Delayed::Job).to receive(:reserve).and_wrap_original do |m, *args|
        raise IOError, 'connection lost' if (calls += 1) == 2
        m.call(*args)
      end
      expect(Delayed::Job.reserve_batch(workers).map(&:first)).to eq [workers.first]
      expect(reported).to eq [['connection lost', 'Reservation']]
    end
  end

  describe 'Worker.lifecycle, first used from several threads at once' do
    it 'is set up once' do
      Delayed::Worker.instance_variable_set(:@lifecycle, nil)
      allow(Delayed::Lifecycle).to receive(:new).and_wrap_original do |m|
        sleep 0.01 # Widens the window for a second setup.
        m.call
      end
      lifecycles = Array.new(8) { Thread.new { Delayed::Worker.lifecycle } }.map(&:value)
      expect(lifecycles.uniq.size).to eq 1
      expect(Delayed::Lifecycle).to have_received(:new).once
    ensure
      Delayed::Worker.setup_lifecycle
    end
  end

  describe 'a worker thread that crashes' do
    let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException -- escapes job handling

    it 'is recorded before ClearLocks unlocks its job, so no poll can hand that job on' do
      Delayed::Job.enqueue(SimpleJob.new)
      crashed_name = nil
      recorded_at_unlock = Concurrent::Array.new
      allow(Delayed::Job).to(receive(:clear_locks!).and_wrap_original do |m, name|
        recorded_at_unlock << !dispatcher.instance_variable_get(:@thread_error).nil? if name == crashed_name
        m.call(name)
      end)
      dispatcher.workers.each do |w|
        allow(w).to receive(:perform_job) do
          crashed_name = w.name
          raise crash, 'escaped'
        end
      end
      expect { run_to_completion(dispatcher) }.to raise_error(crash)
      expect(recorded_at_unlock).not_to be_empty
      expect(recorded_at_unlock).to all(be true)
    end

    it 'stops a poll that finished after it from handing out the jobs it reserved' do
      Delayed::Job.enqueue(SimpleJob.new)
      error = crash.new('escaped')
      allow(dispatcher).to(receive(:poll).and_wrap_original do |m, *args|
        m.call(*args).tap { dispatcher.instance_variable_set(:@thread_error, error) } # A crash meanwhile.
      end)
      expect(dispatcher).not_to receive(:dispatch)
      expect { run_to_completion(dispatcher) }.to raise_error(crash)
      expect(Delayed::Job.all.map(&:locked_by)).to eq [nil] # Its lock cleared as the threads exit.
    end

    it 'is reported once, though both its rescues see it' do
      reported = []
      Delayed::Worker.on_thread_error = ->(e, info) { reported << [e.message, info[:context]] }
      Delayed::Job.enqueue(SimpleJob.new)
      dispatcher.workers.each { |w| allow(w).to receive(:perform_job).and_raise(crash, 'escaped') }
      expect { run_to_completion(dispatcher) }.to raise_error(crash)
      expect(reported).to eq [['escaped', 'Worker thread']]
    end
  end
end
