require 'helper'

# Worker.prefetch: each worker thread holds jobs queued behind the one it
# runs, each locked under a slot name of its own (see Worker.slot_name).
describe 'Prefetching jobs (Worker.prefetch)' do
  let(:log) { Concurrent::Array.new }
  let(:reserves) { Concurrent::Array.new }

  before do
    Delayed::Job.delete_all
    SimpleJob.runs = 0
    GateJob.reset
    ConcurrencyJob.reset(0.01)
  end

  def dispatcher(threads, options = {})
    Delayed::Dispatcher.new({:threads => threads, :sleep_delay => 0.05}.merge(options)).tap { |d| capture_say(log, *and_workers(d)) }
  end

  # Records each reservation: [requested names, reserved count, depth].
  def record_reserves
    allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, slots, *args|
      m.call(slots, *args).tap { |reserved| reserves << [slots.map(&:name), reserved.size] }
    end
  end

  def locked_jobs
    Delayed::Job.all.select(&:locked_by)
  end

  # Builds the dispatcher's slots and inboxes, without starting threads.
  def prepare(dispatcher)
    dispatcher.send(:build_slots)
    dispatcher.workers.each { |w| dispatcher.instance_variable_get(:@inboxes)[w] = Delayed::Inbox.new }
    dispatcher
  end

  def stop_and_join(dispatcher, thread)
    GateJob.release = true
    dispatcher.stop
    Timeout.timeout(10) { thread.join }
  end

  def gate_jobs(count, priority = 0)
    Array.new(count) { |i| Delayed::Job.enqueue(GateJob.new(i), :priority => priority) }
  end

  describe 'Worker settings' do
    it 'defaults to no prefetch, not dynamic' do
      expect(Delayed::Worker.prefetch).to eq 0
      expect(Delayed::Worker.prefetch_dynamic).to be false
    end

    it 'are set by Worker.new options and reset by Worker.reset' do
      Delayed::Worker.new(:prefetch => 2, :prefetch_dynamic => true)
      expect([Delayed::Worker.prefetch, Delayed::Worker.prefetch_dynamic]).to eq [2, true]
      Delayed::Worker.reset
      expect([Delayed::Worker.prefetch, Delayed::Worker.prefetch_dynamic]).to eq [0, false]
    end

    it 'rejects a negative or fractional prefetch' do
      [-1, 21, 1.5, '2', nil].each do |value|
        Delayed::Worker.prefetch = value
        expect { Delayed::Worker.validate_prefetch! }.to raise_error(ArgumentError, /prefetch must be a whole number from 0 to 20/)
      end
    end

    it 'names slots after the worker' do
      expect(Delayed::Worker.slot_name('dj host:h pid:1 thread:2', 3)).to eq 'dj host:h pid:1 thread:2 slot:3'
    end

    it 'lists slot names in lock_names only with prefetch' do
      expect(Delayed::Worker.lock_names('dj ', 1, 2)).to eq Delayed::Worker.lock_names('dj ', 1, 2, 0)
      names = Delayed::Worker.lock_names('dj ', 1, 2, 2)
      expect(names.size).to eq 6
      expect(names.first).to eq Delayed::Worker.slot_name(Delayed::Worker.lock_name('dj ', 1, 0), 0)
      expect(names.last).to eq Delayed::Worker.slot_name(Delayed::Worker.lock_name('dj ', 1, 1), 2)
    end

    it 'refuses to run a dispatcher with an invalid prefetch' do
      Delayed::Worker.prefetch = -1
      expect { Timeout.timeout(5) { dispatcher(1).run } }.to raise_error(ArgumentError, /prefetch/)
    end
  end

  context 'with prefetch 0 (the default)' do
    it 'locks jobs under the plain worker names, one per idle worker' do
      gate_jobs(4)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 }
      sleep 0.2 # Polls meanwhile must not reserve more.
      expect(locked_jobs.map(&:locked_by)).to match_array d.workers.map(&:name)
      stop_and_join(d, thread)
    end

    it 'still runs a job handed over just before stopping' do
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, *args|
        d.stop
        m.call(*args)
      end
      Timeout.timeout(5) { d.run }
      expect(Delayed::Job.count).to eq 0
      expect(SimpleJob.runs).to eq 1
    end
  end

  context 'with prefetch 1' do
    before { Delayed::Worker.prefetch = 1 }

    it 'holds a running and a queued job per worker, under distinct slot names' do
      gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 4 }
      sleep 0.2
      expected = d.workers.flat_map { |w| [0, 1].map { |i| Delayed::Worker.slot_name(w.name, i) } }
      expect(locked_jobs.map(&:locked_by)).to match_array expected
      expect(d.procline).to include '2/2 busy, 2 queued'
      stop_and_join(d, thread)
    end

    it 'starts the next job without waiting for a poll' do
      jobs = gate_jobs(2)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 2 }
      # From now on, polls hang until the jobs are done (every poll: the
      # dispatcher may poll again before it notices the stop).
      polls_open = Concurrent::AtomicBoolean.new(false)
      allow(Delayed::Job).to receive(:reserve_batch) do |*|
        sleep 0.01 until polls_open.true?
        []
      end
      GateJob.release = true
      wait_until { (Delayed::Job.all & jobs).empty? }
      expect(GateJob.finished).to eq [0, 1]
      polls_open.make_true
      d.stop
      Timeout.timeout(10) { thread.join }
    end

    it 'tops up a busy worker as soon as its queued job starts' do
      gate_jobs(5)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 2 }
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      expect(GateJob.finished).to match_array (0...5).to_a
      stop_and_join(d, thread)
    end

    it 'never reserves a job a worker already holds' do
      gate_jobs(1)
      record_reserves
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 }
      sleep 0.3 # Several polls for the free slot while the job runs.
      expect(reserves.size).to be > 1
      expect(reserves.drop(1).map(&:last)).to all(eq 0)
      stop_and_join(d, thread)
      expect(GateJob.finished).to eq [0]
    end

    it 'gives the first jobs to idle workers before queueing any' do
      record_reserves
      d = dispatcher(2)
      slot0 = d.workers.map { |w| Delayed::Worker.slot_name(w.name, 0) }
      slot1 = d.workers.map { |w| Delayed::Worker.slot_name(w.name, 1) }
      gate_jobs(4)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 4 }
      expect(reserves.first.first).to eq slot0 + slot1
      stop_and_join(d, thread)
    end

    it 'runs every job exactly once with exit_on_complete' do
      Delayed::Worker.exit_on_complete = true
      50.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
      Timeout.timeout(30) { dispatcher(4).run }
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...50).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
      expect(Delayed::Job.count).to eq 0
    end

    it 'refreshes the locks of queued jobs too' do
      d = prepare(dispatcher(2))
      slots = d.instance_variable_get(:@slots)
      queued = slots[d.workers.first][1]
      d.send(:dispatch, queued, Delayed::Job.enqueue(SimpleJob.new))
      # Only slot names: no job is locked under the plain worker names.
      expect(d.send(:heartbeat_names)).to eq [queued.name]
    end

    context 'behind a job that overran its max_run_time (stuck, e.g. in native code)' do
      let!(:released) { payloads_of(:jobs_released) }

      # Two workers; the first runs a stuck job with one queued behind it.
      def stuck_setup
        Delayed::Worker.max_run_time = 10
        d = prepare(dispatcher(2))
        worker = d.workers.first
        running, queued = d.instance_variable_get(:@slots)[worker]
        stuck = Delayed::Job.enqueue(SimpleJob.new)
        waiting = Delayed::Job.enqueue(SimpleJob.new)
        [[running, stuck], [queued, waiting]].each do |slot, job|
          job.locked_by = slot.name
          job.locked_at = Delayed::Job.db_time_now
          d.send(:dispatch, slot, job)
        end
        d.instance_variable_get(:@inboxes)[worker].pop # The worker took the stuck job.
        d.instance_variable_get(:@running_slot)[worker] = running
        d.instance_variable_get(:@jobs_started)[worker] = [stuck, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 11, 10, 'Job']
        [d, worker, stuck, waiting]
      end

      it 'releases the queued jobs for other workers, and refreshes neither lock' do
        d, worker, stuck, waiting = stuck_setup
        expect(d.send(:heartbeat_names)).to eq []
        expect(waiting.locked_by).to be_nil
        expect(stuck.locked_by).not_to be_nil
        expect(d.instance_variable_get(:@inboxes)[worker].size).to eq 0
        expect(d.send(:in_flight)).to eq 1
        expect(released).to eq [{:workers => [Delayed::Worker.slot_name(worker.name, 1)], :count => 1, :reason => 'stuck job'}]
        expect(log).to include(['warn', 'Released 1 queued job(s) queued behind a job that overran its max_run_time'])
      end

      it 'queues no more jobs behind it, until it finishes' do
        d, worker, = stuck_setup
        other = d.workers.last
        d.send(:heartbeat_names)
        owners = d.send(:snapshot).first.map { |slot| d.instance_variable_get(:@slot_owner)[slot] }
        expect(owners.uniq).to eq [other]
        d.send(:untrack_job_after, worker) { nil } # The stuck job ends at last.
        owners = d.send(:snapshot).first.map { |slot| d.instance_variable_get(:@slot_owner)[slot] }
        expect(owners.uniq).to contain_exactly(worker, other)
      end

      it 'releases them once, however many heartbeats follow' do
        d, = stuck_setup
        3.times { d.send(:heartbeat_names) }
        expect(released.size).to eq 1
      end
    end
  end

  describe 'queued job order' do
    before { Delayed::Worker.prefetch = 2 }

    it 'runs a more urgent job reserved later before those already queued' do
      Delayed::Job.enqueue(GateJob.new(:running), :priority => 0)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 }
      Delayed::Job.enqueue(GateJob.new(:normal), :priority => 5)
      wait_until { locked_jobs.size == 2 }
      Delayed::Job.enqueue(GateJob.new(:urgent), :priority => -5)
      wait_until { locked_jobs.size == 3 }
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      expect(GateJob.finished).to eq %i(running urgent normal)
      stop_and_join(d, thread)
    end
  end

  describe 'a queued job whose lock expires (no lock heartbeats)' do
    before { Delayed::Worker.prefetch = 1 }

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def a_slot(dispatcher)
      dispatcher.instance_variable_get(:@slots)[dispatcher.workers.first][1]
    end

    it 'runs with what is left of max_run_time as its time limit' do
      Delayed::Worker.max_run_time = 60
      d = prepare(dispatcher(1))
      expect(d.send(:lock_time_left, a_slot(d), now - 15.5)).to eq 44
    end

    it 'has no extra limit after a short wait' do
      d = prepare(dispatcher(1))
      expect(d.send(:lock_time_left, a_slot(d), now - 0.5)).to be_nil
    end

    it 'passes the time left to the worker running a job that waited' do
      Delayed::Worker.max_run_time = 60
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      caps = Concurrent::Array.new
      allow(d.workers.first).to receive(:perform_job) { |_job, cap| caps << cap }
      allow(d).to receive(:dispatch).and_wrap_original do |m, slot, reserved, reserved_at|
        m.call(slot, reserved, reserved_at - 20.5) # As if it had waited 20.5s.
      end
      thread = run_in_thread(d)
      wait_until { caps.any? }
      expect(caps.first).to eq 39
      d.stop
      Timeout.timeout(10) { thread.join }
    end

    it 'times the job out at the lock expiry rather than its max_run_time' do
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      job = Delayed::Job.enqueue(LongRunningJob.new)
      expect(Timeout).to receive(:timeout).with(7, Delayed::WorkerTimeout)
      worker.run(job, 7)
    end

    it "keeps a job's own shorter max_run_time" do
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      job = Delayed::Job.enqueue(LongRunningJob.new)
      allow(job).to receive(:max_run_time).and_return(3)
      expect(Timeout).to receive(:timeout).with(3, Delayed::WorkerTimeout)
      worker.run(job, 7)
    end

    it 'releases the job unstarted once its lock expired in the queue' do
      released = payloads_of(:jobs_released)
      jobs = gate_jobs(2)
      d = dispatcher(1)
      aged = Concurrent::AtomicBoolean.new(false)
      allow(d).to receive(:dispatch).and_wrap_original do |m, slot, job, reserved_at|
        # The first time it is handed over, as if it had waited max_run_time
        # since its lock was taken; reserved again, it gets a fresh lock.
        age = job.id == jobs[1].id && aged.make_true ? Delayed::Worker.max_run_time : 0
        m.call(slot, job, reserved_at - age)
      end
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 2 }
      expect(released).to be_empty
      GateJob.release = true # The queued job is taken next: its lock expired.
      wait_until { Delayed::Job.count.zero? } # Reserved again, and run.
      expect(released.size).to eq 1
      expect(released.first).to include(:reason => 'lock expired in queue', :count => 1)
      expect(log.map(&:last).grep(/waited in its queue until its lock expired/).size).to eq 1
      expect(GateJob.finished).to eq [0, 1]
      stop_and_join(d, thread)
    end
  end

  context 'with prefetch 2' do
    before { Delayed::Worker.prefetch = 2 }

    it 'reserves 3 for an idle worker, then tops it back up to 3' do
      record_reserves
      gate_jobs(10)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 3 }
      expect(reserves.first.last).to eq 3
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      stop_and_join(d, thread)
      expect(GateJob.finished.size).to eq 10
    end

    it 'gives a busy worker with an empty queue 2 more jobs' do
      d = dispatcher(1)
      gate_jobs(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 }
      record_reserves
      gate_jobs(5)
      wait_until { locked_jobs.size == 3 }
      # In one reservation, or two if it polled while the jobs were enqueued.
      expect(reserves.sum(&:last)).to eq 2
      stop_and_join(d, thread)
    end
  end

  context 'with prefetch_dynamic' do
    before do
      Delayed::Worker.prefetch = 2
      Delayed::Worker.prefetch_dynamic = true
    end

    let(:depths) { Concurrent::Array.new }

    def record_depths
      subscribe(:jobs_reserved) { |*, payload| depths << [payload[:depth], payload[:requested], payload[:reserved]] }
      yield
    end

    it 'starts at depth 0, grows one level per full poll and polls again at once' do
      gate_jobs(20)
      d = dispatcher(2, :sleep_delay => 30)
      thread = nil
      record_depths do
        thread = run_in_thread(d)
        wait_until { locked_jobs.size == 6 }
      end
      # 2 idle workers, then 2 more queued, then 2 more: full each time.
      expect(depths.first(3)).to eq [[0, 2, 2], [1, 2, 2], [2, 2, 2]]
      stop_and_join(d, thread)
    end

    it 'drops back to depth 0 after a partial poll, leaving queued jobs to run' do
      gate_jobs(5)
      d = dispatcher(2)
      thread = nil
      record_depths do
        thread = run_in_thread(d)
        wait_until { locked_jobs.size == 5 }
        sleep 0.2
      end
      # Depth 0: 2 of 2; depth 1: 2 of 2; depth 2: 1 of 2 -> back to 0.
      # Both workers are busy, so at depth 0 there is nothing to poll for.
      expect(depths).to eq [[0, 2, 2], [1, 2, 2], [2, 2, 1]]
      expect(d.procline).to include 'depth 0/2'
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      stop_and_join(d, thread)
      expect(GateJob.finished).to match_array (0...5).to_a
    end

    it 'leaves the depth alone when a poll asks for nothing' do
      d = dispatcher(1)
      d.instance_variable_set(:@prefetch, 2)
      d.instance_variable_set(:@depth, 1)
      expect(d.send(:adjust_depth, 0, 0)).to be false
      expect(d.instance_variable_get(:@depth)).to eq 1
      expect(d.send(:adjust_depth, 2, 2)).to be true
      expect(d.send(:adjust_depth, 2, 2)).to be false # Capped at prefetch.
      expect(d.instance_variable_get(:@depth)).to eq 2
    end

    it 'runs every job exactly once with exit_on_complete' do
      Delayed::Worker.exit_on_complete = true
      50.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
      Timeout.timeout(30) { dispatcher(4).run }
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...50).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
    end
  end

  describe 'a crashed worker thread' do
    before { Delayed::Worker.prefetch = 1 }

    it 'releases its queued jobs and frees its slots' do
      gate_jobs(4)
      d = dispatcher(2)
      crash = Queue.new
      crash_error = Class.new(Exception) # rubocop:disable Lint/InheritException -- not rescued by job handling
      allow(d.workers.first).to receive(:perform_job) do
        crash.pop
        raise crash_error, 'boom'
      end
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 4 }
      crash << :go
      GateJob.release = true # The other worker's job finishes as it stops.
      expect { Timeout.timeout(10) { thread.join } }.to raise_error(crash_error, 'boom')
      running_dispatchers.clear # Already joined.
      expect(d.send(:in_flight)).to eq 0
      expect(d.send(:free_slots)).to all(satisfy { |slot| d.instance_variable_get(:@slot_owner)[slot] != d.workers.first })
      left = Delayed::Job.all.reject { |job| GateJob.finished.include?(job.payload_object.key) }
      expect(left).to all(satisfy { |job| job.reload.locked_by.nil? })
    end
  end

  describe 'shutdown with queued jobs' do
    before { Delayed::Worker.prefetch = 2 }

    let(:released) { Concurrent::Array.new }

    def track_releases
      subscribe(:jobs_released) { |*, payload| released << payload }
      yield
    end

    def unlocked?(job)
      job.reload
      job.locked_by.nil? && job.locked_at.nil? && job.attempts.zero?
    end

    it 'releases queued jobs unstarted and lets running ones finish' do
      jobs = gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      track_releases do
        d.stop
        wait_until { locked_jobs.size == 2 }
        GateJob.release = true
        Timeout.timeout(10) { thread.join }
      end
      expect(GateJob.finished.size).to eq 2
      left = Delayed::Job.all
      expect(left.size).to eq 4
      expect(left).to all(satisfy { |job| unlocked?(job) })
      expect(released.first).to include(:count => 4, :reason => 'shutdown')
      expect(released.first[:workers].size).to eq 4
      expect(log.map(&:last)).to include 'Released 4 queued job(s) on shutdown'
      expect(jobs.size).to eq 6
    end

    it 'releases queued and running jobs on quit' do
      gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      d.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted.size).to eq 2
      expect(Delayed::Job.all.size).to eq 6
      expect(Delayed::Job.all).to all(satisfy { |job| unlocked?(job) })
    end

    it 'releases everything once the shutdown timeout passes' do
      Delayed::Worker.shutdown_timeout = 0.2
      gate_jobs(4)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 3 }
      d.stop
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [0]
      expect(Delayed::Job.all).to all(satisfy { |job| unlocked?(job) })
    end

    it 'does not start a job a worker took after stop was requested' do
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, *args|
        d.stop # As the job is handed over: the worker takes it after stop.
        m.call(*args)
      end
      allow(d).to receive(:release_queued) # Leave it to the worker.
      Timeout.timeout(5) { d.run }
      expect(SimpleJob.runs).to eq 0
      job = Delayed::Job.all.first
      expect([job.locked_by, job.locked_at, job.attempts]).to eq [nil, nil, 0]
      expect(log.map(&:last).grep(/not started before shutdown/).size).to eq 1
    end

    it 'clears the slot locks as threads exit, after releasing queued jobs failed' do
      gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      # Stubs are set up here, on this thread: rspec-mocks isn't thread-safe.
      failing = Concurrent::AtomicBoolean.new(false)
      allow(Delayed::Job).to receive(:clear_locks!).and_wrap_original do |orig, names|
        raise IOError, 'down' if failing.true?
        orig.call(names)
      end
      allow(d).to receive(:release_queued).and_wrap_original do |m|
        failing.make_true
        m.call
      ensure
        failing.make_false
        # Only now: threads that finished their jobs earlier would take
        # their queued jobs and release them themselves (see #work_jobs).
        GateJob.release = true
      end
      d.stop
      Timeout.timeout(10) { thread.join }
      expect(log.map(&:last)).to include 'Could not release the queued jobs: IOError: down'
      expect(Delayed::Job.all.size).to eq 4
      expect(Delayed::Job.all).to all(satisfy { |job| unlocked?(job) })
    end

    it 'clears the slot locks of a reserved job that was never handed over' do
      jobs = gate_jobs(2)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, slot, job|
        next m.call(slot, job) unless job.id == jobs[1].id
        d.stop
        raise SignalException, 'TERM' # Raised by the trap as the jobs are handed over.
      end
      expect { Timeout.timeout(10) { d.run } }.to raise_error(SignalException)
      # The first job may have started (on JRuby, in parallel) and then been
      # interrupted by the signal; the second one never reached its thread.
      expect(unlocked?(jobs[1])).to be true
    end

    it 'logs and reports a failure to release queued jobs' do
      reported = Concurrent::Array.new
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error.message, info[:context]] }
      gate_jobs(3)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 3 }
      allow(Delayed::Job).to receive(:clear_locks!).and_raise(IOError, 'down')
      d.stop
      wait_until { reported.any? } # Queued jobs drained before the running one finishes.
      GateJob.release = true
      Timeout.timeout(10) { thread.join }
      expect(reported).to include ['down', 'Releasing interrupted jobs']
      expect(log.map(&:last)).to include 'Could not release the queued jobs: IOError: down'
      expect(d.send(:in_flight)).to eq 0
    end
  end

  describe 'a queued job whose lock expires, with lock heartbeats' do
    let(:heartbeat_stop) { Queue.new }
    let(:heartbeat_thread) { Thread.new { heartbeat_stop.pop } } # Alive until the example ends.

    before do
      Delayed::Worker.prefetch = 1
      Delayed::Worker.lock_heartbeat_interval = 10
      Delayed::Worker.lock_timeout = 60
      Delayed::Worker.max_run_time = 3600
      allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
    end

    after do
      heartbeat_stop << :stop
      heartbeat_thread.join
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A dispatcher whose heartbeat last refreshed locks `ago` seconds ago.
    def heartbeat_dispatcher(ago:, alive: true)
      d = prepare(dispatcher(1))
      d.instance_variable_set(:@heartbeat, alive ? heartbeat_thread : Thread.new {}.tap(&:join))
      d.instance_variable_set(:@last_beat_at, now - ago)
      d
    end

    def held(dispatcher, refreshed_ago: nil)
      slot = dispatcher.instance_variable_get(:@slots)[dispatcher.workers.first][1]
      dispatcher.send(:dispatch, slot, Delayed::Job.enqueue(SimpleJob.new), now - 3000)
      dispatcher.instance_variable_get(:@slot_refreshed)[slot] = now - refreshed_ago if refreshed_ago
      slot
    end

    it 'starts a job reserved just now, even with a lock_timeout under a second' do
      Delayed::Worker.lock_heartbeat_interval = 0.1
      Delayed::Worker.lock_timeout = 0.5
      d = heartbeat_dispatcher(:ago => 0.05)
      slot = held(d)
      expect(d.send(:lock_time_left, slot, now)).to be_nil
      d.instance_variable_set(:@heartbeat, Thread.new {}.tap(&:join))
      expect(d.send(:lock_time_left, slot, now)).to be_between(0.4, 0.5)
    end

    it 'has no extra limit while the heartbeat keeps its lock alive' do
      d = heartbeat_dispatcher(:ago => 5)
      expect(d.send(:lock_time_left, held(d, :refreshed_ago => 5), now - 3000)).to be_nil
    end

    it 'is released when its lock was not refreshed for lock_timeout' do
      d = heartbeat_dispatcher(:ago => 5)
      slot = held(d) # Reserved 3000s ago, never refreshed (e.g. failed beats).
      expect(d.send(:lock_time_left, slot, now - 3000)).to be <= 0
    end

    it 'is limited to its lock expiry once the heartbeat gave up' do
      d = heartbeat_dispatcher(:ago => 30, :alive => false)
      expect(d.send(:lock_time_left, held(d, :refreshed_ago => 30), now - 3000)).to eq 29
    end

    it 'is limited to its lock expiry while a refresh hangs for lock_timeout' do
      d = heartbeat_dispatcher(:ago => 61)
      slot = held(d, :refreshed_ago => 59.5)
      expect(d.send(:lock_time_left, slot, now - 3000)).to be_between(0.4, 0.5) # Under a second: not rounded down to none.
      d.instance_variable_get(:@slot_refreshed)[slot] = now - 61
      expect(d.send(:lock_time_left, slot, now - 3000)).to be <= 0
    end

    describe 'the heartbeat' do
      it 'records when it refreshed the lock of each job it reached' do
        d = heartbeat_dispatcher(:ago => 30)
        slot = held(d)
        allow(Delayed::Job).to receive(:touch_locks).and_return(1)
        before = now
        d.send(:heartbeat)
        expect(d.instance_variable_get(:@slot_refreshed)[slot]).to be_between(before, now)
        expect(d.instance_variable_get(:@last_beat_at)).to be_between(before, now)
      end

      it 'does not count a refresh for a job that took the slot meanwhile' do
        d = heartbeat_dispatcher(:ago => 30)
        slot = held(d)
        allow(Delayed::Job).to receive(:touch_locks) do
          d.send(:synchronize) { d.send(:free_slot, slot) }
          d.send(:dispatch, slot, Delayed::Job.enqueue(SimpleJob.new))
          1
        end
        d.send(:heartbeat)
        expect(d.instance_variable_get(:@slot_refreshed)).not_to have_key(slot)
      end

      it 'records nothing when the refresh fails' do
        d = heartbeat_dispatcher(:ago => 30)
        slot = held(d)
        allow(Delayed::Job).to receive(:touch_locks).and_raise(IOError, 'gone')
        allow(d).to receive(:thread_error)
        d.send(:heartbeat)
        expect(d.instance_variable_get(:@slot_refreshed)).not_to have_key(slot)
      end

      it 'forgets the refresh once the slot is freed' do
        d = heartbeat_dispatcher(:ago => 30)
        slot = held(d, :refreshed_ago => 1)
        d.send(:synchronize) { d.send(:free_slot, slot) }
        expect(d.instance_variable_get(:@slot_refreshed)).not_to have_key(slot)
      end
    end

    it 'runs a queued job end to end after the heartbeat stopped, timed out at its lock expiry' do
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      caps = Concurrent::Array.new
      allow(d.workers.first).to receive(:perform_job) { |_job, cap| caps << cap }
      allow(d).to receive(:start_lock_heartbeat).and_return(false) # As if it had died.
      allow(d).to receive(:heartbeat_alive?).and_return(false)
      allow(d).to receive(:dispatch).and_wrap_original do |m, slot, reserved, reserved_at|
        m.call(slot, reserved, reserved_at - 20.5)
      end
      thread = run_in_thread(d)
      wait_until { caps.any? }
      expect(caps.first).to eq 39 # lock_timeout 60 - 20.5
      d.stop
      Timeout.timeout(10) { thread.join }
    end
  end
end
