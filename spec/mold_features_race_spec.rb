require 'helper'

# The mold process crossed with per-process worker features (threads,
# prefetch, lock heartbeats, pools, shutdown_timeout, fork safety), at unit
# level. The process level is in spec/processes/mold_features_race_spec.rb.
describe 'Mold process with worker features' do
  describe Delayed::Dispatcher do
    let(:log) { Concurrent::Array.new }
    let(:released) { Concurrent::Array.new }

    before do
      Delayed::Job.delete_all
      GateJob.reset
    end

    after { stop_running_dispatchers }

    def dispatcher(options = {})
      described_class.new({:threads => 1, :sleep_delay => 0.01}.merge(options)).tap { |d| capture_say(log, *and_workers(d)) }
    end

    def locked_jobs
      Delayed::Job.all.select(&:locked_by)
    end

    def heartbeat_thread(dispatcher)
      dispatcher.instance_variable_get(:@heartbeat)
    end

    # The test backend has no lock heartbeats: fake the refresh.
    def enable_heartbeats(&touch)
      Delayed::Worker.lock_heartbeat_interval = 0.05
      Delayed::Worker.lock_timeout = 5
      allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
      touch ||= proc { 0 }
      allow(Delayed::Job).to receive(:touch_locks, &touch)
    end

    it 'finishes the job on every thread, releases every queued one as promotion, and stops the heartbeat before a mold could fork' do
      enable_heartbeats
      jobs = Array.new(6) { |i| Delayed::Job.enqueue(GateJob.new(i)) }
      subscribe(:jobs_released) { |*, payload| released << payload }
      d = dispatcher(:threads => 2, :prefetch => 2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      d.promote
      wait_until { locked_jobs.size == 2 } # Queued ones released at once; running ones kept.
      expect(heartbeat_thread(d)).to be_alive # Still refreshing the running jobs' locks.
      GateJob.release = true
      Timeout.timeout(10) { thread.join }

      expect(d).to be_promoted
      expect(d.jobs_performed).to eq 2
      expect(GateJob.finished.size).to eq 2
      expect(released.map { |payload| payload[:reason] }.uniq).to eq ['promotion']
      expect(released.sum { |payload| payload[:count] }).to eq 4
      left = Delayed::Job.all
      expect(left.size).to eq 4
      expect(left).to all(satisfy { |job| job.locked_by.nil? && job.attempts.zero? })
      expect(jobs.size).to eq 6
      expect(heartbeat_thread(d)).not_to be_alive
      expect(d).to be_cleanly_stopped
    end

    it 'is not cleanly stopped when promoted while a lock refresh hangs, so no mold forks a frozen heartbeat' do
      stub_const('Delayed::Dispatcher::HEARTBEAT_STOP_TIMEOUT', 0.2)
      stuck = Queue.new
      unstick = Queue.new
      enable_heartbeats do
        stuck << true
        unstick.pop # A database call that hangs.
        0
      end
      d = dispatcher
      thread = run_in_thread(d)
      Timeout.timeout(5) { stuck.pop }
      d.promote
      Timeout.timeout(5) { thread.join }

      expect(d).to be_promoted
      expect(d).not_to be_cleanly_stopped
      unstick << true # The refresh returns: the heartbeat stops at its next beat.
      expect(heartbeat_thread(d).join(5)).to eq heartbeat_thread(d)
      expect(d).to be_cleanly_stopped
    end

    describe 'shutdown_timeout while promoted' do
      before do
        Delayed::Worker.shutdown_timeout = 0.2
        Delayed::Worker.count_shutdown_interrupts = true
      end

      it 'interrupts and releases a draining job without counting an attempt, even with count_shutdown_interrupts' do
        job = Delayed::Job.enqueue(GateJob.new(0))
        d = dispatcher
        thread = run_in_thread(d)
        Timeout.timeout(5) { GateJob.started.pop }
        d.promote
        Timeout.timeout(10) { thread.join }

        expect(GateJob.interrupted).to eq [0]
        expect(d).to be_promoted
        expect(d).to be_cleanly_stopped
        job = Delayed::Job.find(job.id)
        expect([job.locked_by, job.attempts, job.last_error]).to eq [nil, 0, nil]
        expect(log.map(&:last).grep(/counted as a failed attempt/)).to be_empty
      end

      it 'counts the attempt once a stop signal cancels the promotion mid-drain' do
        job = Delayed::Job.enqueue(GateJob.new(0))
        d = dispatcher
        thread = run_in_thread(d)
        Timeout.timeout(5) { GateJob.started.pop }
        d.promote
        d.send(:handle_pending_signal, 'TERM') # As the trap does: the stop is now a shutdown.
        Timeout.timeout(10) { thread.join }

        expect(d).to be_promotion_cancelled
        job = Delayed::Job.find(job.id)
        expect([job.locked_by, job.attempts]).to eq [nil, 1]
      end
    end

    # A worker thread can pop a queued job between #promote and the
    # dispatcher thread draining the inboxes (#stop_threads).
    it 'releases a queued job a worker pops after promotion with reason promotion' do
      subscribe(:jobs_released) { |*, payload| released << payload }
      d = dispatcher(:prefetch => 1)
      d.send(:build_slots)
      worker = d.workers.first
      slot = d.instance_variable_get(:@slots)[worker].last
      inbox = d.instance_variable_get(:@inboxes)[worker] = Delayed::Inbox.new
      job = Delayed::Job.enqueue(SimpleJob.new)
      expect(job.lock_exclusively!(Delayed::Worker.max_run_time, slot.name)).to be true
      d.send(:dispatch, slot, job)
      d.promote
      inbox.close
      d.send(:work_jobs, worker, inbox)

      expect(Delayed::Job.find(job.id).locked_by).to be_nil
      expect(released.map { |payload| payload[:reason] }).to eq ['promotion']
    end
  end

  describe Delayed::Launcher::Forking do
    before { Delayed::Job.delete_all }

    # Locks a job under each of a child process's lock names (threads x slots).
    def lock_under_every_name(worker_name, pid, threads, prefetch)
      Delayed::Worker.lock_names("#{worker_name} ", pid, threads, prefetch).map do |name|
        Delayed::Job.enqueue(SimpleJob.new).tap { |job| job.lock_exclusively!(Delayed::Worker.max_run_time, name) }
      end
    end

    def recover(launcher, status, promoted)
      launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 4242, {:threads => 3, :prefetch => 2}, status, :promoted => promoted)
    end

    let(:launcher) { described_class.new(:mold => true).tap { |l| allow(l).to receive(:disconnect_backend) } }

    it 'clears the lock of every thread and slot of a promoted child that forked no mold (75), without an attempt' do
      jobs = lock_under_every_name('delayed_job.1', 4242, 3, 2)
      expect(jobs.size).to eq 9
      recover(launcher, Delayed::ReportedStatus.new(4242, Delayed::Launcher::Mold::PROMOTION_FAILED, nil), true)

      expect(jobs.map { |job| [job.locked_by, job.attempts] }.uniq).to eq [[nil, 0]]
    end

    it 'counts an attempt for every job a promoted child held when it was SIGKILLed while draining' do
      jobs = lock_under_every_name('delayed_job.1', 4242, 3, 2)
      recover(launcher, Delayed::ReportedStatus.new(4242, nil, 9), true)

      expect(jobs.map { |job| [job.locked_by, job.attempts] }.uniq).to eq [[nil, 1]]
    end
  end

  describe Delayed::Launcher::MoldSupervisor do
    # A stand-in for the forking launcher (see spec/mold_race_spec.rb).
    let(:launcher_class) do
      Class.new do
        attr_reader :workers, :started, :logged
        attr_accessor :stopped, :pools, :supervisor, :shutdown_timeout

        def initialize
          @workers = {}
          @started = []
          @logged = []
          @stopped = false
        end

        def stopped?
          @stopped
        end

        def stopping?
          @stopped
        end

        def child_name(index)
          "delayed_job.#{index}"
        end

        def logger
          log = @logged
          Object.new.tap { |l| %i(info warn error debug).each { |m| l.define_singleton_method(m) { |msg| log << msg } } }
        end

        def add_worker_safely(options, replaces_pid = nil)
          @started << [:add, options, replaces_pid]
          nil
        end

        def start_child_safely(index, options, spawn)
          @started << [:start, index, options, spawn]
        end

        def child_started(name, pid, options, spawn)
          @workers[pid] = [name, options]
          @started << [:child, pid, spawn]
          supervisor&.child_started(pid, spawn)
        end

        def handle_exit(pid, _status)
          @workers.delete(pid)
        end
      end
    end
    let(:launcher) { launcher_class.new }
    let(:fork_records) { [] }
    let(:pipes) do
      instance_double(Delayed::Launcher::Mold::Pipes, :drain_fork_requests => nil, :each_status => nil).tap do |double|
        allow(double).to receive(:request_fork) { |*record| fork_records << record }
      end
    end
    let(:supervisor) { described_class.new(launcher, [5], pipes, true).tap { |s| launcher.supervisor = s } }
    let(:signals) { [] }

    before { allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] } }

    around do |example|
      deadline = described_class.drain_deadline
      example.run
    ensure
      described_class.drain_deadline = deadline
    end

    def line(type, *args)
      supervisor.send(:handle_status, type, *args)
    end

    def boot(pid, options = {}, spawn = {})
      launcher.workers[pid] = ["delayed_job.#{pid}", options]
      supervisor.child_started(pid, spawn)
      line('b', pid)
    end

    def ping(pid, jobs, busy = 0)
      line('p', pid, jobs, busy, 0)
    end

    def ok(pid)
      Delayed::ReportedStatus.new(pid, 0, nil)
    end

    def promoted_pid
      signals.select { |signal, _| signal == 'URG' }.map(&:last).last
    end

    describe 'choosing the child to promote' do
      it 'promotes the child with the most jobs when every child is busy' do
        boot(10)
        boot(11)
        boot(12)
        ping(10, 2, 1)
        ping(12, 4, 3)
        ping(11, 6, 2) # Past the threshold.
        expect(promoted_pid).to eq 11
      end

      it 'skips a fork-unsafe idle child for a fork-safe busy one, once that one is past the threshold' do
        boot(10)
        boot(11)
        ping(11, 3, 2)
        line('p', 10, 9, 0, 1) # Idle, past the threshold, but fork unsafe.
        expect(promoted_pid).to be_nil # No other child is warm enough yet.
        ping(11, 6, 2)
        expect(promoted_pid).to eq 11
      end

      it 'promotes a child past the threshold rather than an idle one that has performed no job' do
        boot(10)
        boot(11) # E.g. just respawned: idle, no job performed.
        ping(10, 6, 1)
        expect(promoted_pid).to eq 10
      end
    end

    # A slot whose fork request is held while a promoted mold isn't ready
    # (#holding_forks?) is forked by that mold once it activates.
    it 'records a child forked for a request held during a promotion as of the generation of the mold that forked it' do
      boot(10)
      boot(11)
      ping(10, 6)
      line('M', 10, 900)
      line('m', 900, 10)
      supervisor.child_exited(10, ok(10), {})
      supervisor.request_fork(0, {}, :generation => 1) # The promoted child's slot.
      line('f', 900, 20, 0)
      line('b', 20, 0, 900)
      supervisor.child_exited(11, ok(11), {}) # Gone: every child is of generation 1.
      expect(supervisor.generation).to eq 1

      # Second promotion; meanwhile a generation 1 child crashes and is replaced.
      supervisor.request_promotion
      supervisor.send(:handle_promotion_requests)
      line('M', promoted_pid, 901)
      supervisor.request_fork(1, {}, :generation => supervisor.generation) # As Forking#add_worker does.
      supervisor.send(:send_fork_requests)
      expect(fork_records.map(&:first)).not_to include 1 # Held: mold 901 isn't ready.
      line('m', 901, promoted_pid)
      expect(supervisor.generation).to eq 2
      supervisor.send(:send_fork_requests)

      expect(fork_records.find { |index, _, _| index == 1 }.last).to eq 2
      line('f', 901, 21, 1)
      line('b', 21, 1, 901)
      expect(supervisor.send(:current?, supervisor.instance_variable_get(:@children)[21])).to be true
    end

    describe 'pools' do
      before { launcher.pools = [[['a'], 1], [['b'], 1]] }

      it "refills a promoted pool B child's slot with pool B's queues once its mold is ready" do
        boot(10, :queues => ['a'])
        boot(11, :queues => ['b'])
        ping(10, 1)
        ping(11, 6)
        expect(promoted_pid).to eq 11
        line('M', 11, 900)
        line('m', 900, 11)
        expect(supervisor.child_exited(11, ok(11), :queues => ['b'])).to be true

        refill = launcher.started.find { |entry| entry.first == :add && entry.last == 11 }
        expect(refill).to eq [:add, {:queues => ['b']}, 11]
        expect(Delayed::Launcher::Mold.pool_index(launcher.pools, refill[1])).to eq 1
      end

      it "refills a draining pool B child's slot with pool B's queues after the drain deadline" do
        described_class.drain_deadline = 0
        boot(10, :queues => ['a'])
        boot(11, :queues => ['b'])
        ping(11, 6, 0)
        supervisor.send(:check_promotion)

        expect(launcher.started).to include [:add, {:queues => ['b']}, 11]
        expect(supervisor.child_exited(11, ok(11), :queues => ['b'])).to be true
        expect(launcher.started.count { |entry| entry.first == :add }).to eq 1 # Not refilled again.
      end
    end

    it 'names the shutdown timeout given as a launcher option (--shutdown-timeout) when refilling a draining slot' do
      described_class.drain_deadline = 0
      forking = Delayed::Launcher::Forking.new(:mold => true, :shutdown_timeout => 7)
      allow(forking).to receive(:logger).and_return(launcher.logger)
      allow(forking).to receive(:add_worker_safely)
      real = described_class.new(forking, [5], pipes, true)
      forking.workers[10] = ['delayed_job.0', {}]
      real.child_started(10, {})
      real.send(:handle_status, 'p', 10, 6, 1, 0)
      real.send(:check_promotion)

      expect(launcher.logged.join("\n")).to include 'or shutdown_timeout of 7s'
    end
  end
end
