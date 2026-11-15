require 'helper'

# Worker.mold (see Launcher::Mold and Launcher::MoldSupervisor); the forking
# itself is covered by spec/processes/mold_spec.rb.
describe 'Mold process (Worker.mold)' do
  describe 'the setting' do
    it 'is off by default, set by Worker.new and reset by Worker.reset' do
      expect(Delayed::Worker.mold).to be_nil
      Delayed::Worker.new(:mold => [10, 20])
      expect(Delayed::Worker.mold).to eq [10, 20]
      Delayed::Worker.reset
      expect(Delayed::Worker.mold).to be_nil
    end

    it 'normalises to thresholds' do
      expect(Delayed::Worker.mold_thresholds(nil)).to be_nil
      expect(Delayed::Worker.mold_thresholds(false)).to be_nil
      expect(Delayed::Worker.mold_thresholds(true)).to eq [1000]
      expect(Delayed::Worker.mold_thresholds(50)).to eq [50]
      expect(Delayed::Worker.mold_thresholds([5, 10])).to eq [5, 10]
    end

    [0, -1, 1.5, 'x', []].each do |value|
      it "rejects #{value.inspect}" do
        expect { Delayed::Worker.validate_settings!(:mold => value) }.to raise_error(ArgumentError, /mold must be true or job counts greater than 0/)
      end
    end
  end

  describe 'the command line and rake' do
    it 'parses --mold, with or without thresholds' do
      expect(Delayed::Command.new(%w[--fork --mold]).instance_variable_get(:@options)[:mold]).to be true
      expect(Delayed::Command.new(%w[--fork --mold=100,200]).instance_variable_get(:@options)[:mold]).to eq [100, 200]
      expect { Delayed::Command.new(%w[--fork --mold=0]) }.to raise_error(ArgumentError, '--mold must be job counts greater than 0')
    end

    it 'parses MOLD' do
      expect(Delayed::LaunchOptions.parse_mold(' 30 ', 'MOLD')).to eq 30
      expect { Delayed::LaunchOptions.parse_mold('x', 'MOLD') }.to raise_error(ArgumentError, 'MOLD must be job counts greater than 0')
    end
  end

  describe 'launcher guards' do
    it 'refuses the daemonized launcher' do
      expect { Delayed::Launcher::Daemonized.new(:mold => true) }.to raise_error(ArgumentError, '--mold is for --fork mode')
    end

    it 'refuses --identifier' do
      launcher = Delayed::Launcher::Forking.new(:mold => true, :identifier => '1')
      expect { launcher.launch }.to raise_error(ArgumentError, 'mold cannot be used with --identifier')
    end

    it 'refuses platforms without fork', :fork_guard do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      allow(launcher).to receive(:fork_available?).and_return(false)
      expect { launcher.launch }.to raise_error(NotImplementedError, /mold needs fork/)
    end

    it 'uses up a worker index only once a fork succeeds (without mold)' do
      launcher = Delayed::Launcher::Forking.new({})
      launcher.instance_variable_set(:@stop_signals, Concurrent::Array.new)
      allow(launcher).to receive(:fork_worker).and_raise(Errno::EAGAIN)
      expect { launcher.send(:add_worker, {}) }.to raise_error(Errno::EAGAIN)
      expect(launcher.instance_variable_get(:@worker_index)).to eq 0
    end

    it "clears a promoted child's leftover locks without an attempt when it forks no mold (status 75)" do
      launcher = Delayed::Launcher::Forking.new({})
      allow(launcher).to receive(:disconnect_backend)
      expect(Delayed::Job).to receive(:clear_locks!)
      expect(Delayed::Worker).not_to receive(:recover_jobs_of)
      status = Delayed::ReportedStatus.new(10, Delayed::Launcher::Mold::PROMOTION_FAILED, nil)
      launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 10, {}, status, :promoted => true)
    end

    it "still recovers a child's jobs with an attempt when it exits 75 unpromoted" do
      launcher = Delayed::Launcher::Forking.new({})
      allow(launcher).to receive(:disconnect_backend)
      expect(Delayed::Worker).to receive(:recover_jobs_of).and_return(0)
      status = Delayed::ReportedStatus.new(10, Delayed::Launcher::Mold::PROMOTION_FAILED, nil)
      launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 10, {}, status)
    end

    it 'is off with exit_on_complete, which would never promote' do
      expect(Delayed::Launcher::Forking.new(:mold => true, :exit_on_complete => true).send(:molding?)).to be false
    end

    it 'skips a queued replacement whose refork step was aborted (the old child keeps its slot)' do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      launcher.instance_variable_set(:@stop_signals, Concurrent::Array.new)
      supervisor = instance_double(Delayed::Launcher::MoldSupervisor, :replacement_needed? => false)
      launcher.instance_variable_set(:@mold_supervisor, supervisor)
      expect(launcher).not_to receive(:fork_worker)
      expect(launcher.send(:respawn, 'delayed_job.1', 11, {}, nil, 1, 0)).to be_nil
    end

    it "reports a mold's error (e.g. in a :mold hook) to on_thread_error as context Mold, and exits 1" do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      allow(launcher).to receive(:logger).and_return(Logger.new(nil))
      allow_any_instance_of(Delayed::Launcher::Mold).to receive(:run).and_raise(RuntimeError, 'hook failed')
      errors = []
      allow(Delayed::Worker).to receive(:thread_error) { |error, context| errors << [error.message, context] }
      expect(launcher).to receive(:flush_and_exit!).with(1)
      launcher.send(:run_mold, 'delayed_job.1', {:generation => 1}, 1)
      expect(errors).to eq [['hook failed', {:context => 'Mold', :pid => Process.pid}]]
    end

    it 'flushes stdout and stderr before exit!, which skips at_exit' do
      launcher = Delayed::Launcher::Forking.new({})
      expect($stdout).to receive(:flush).ordered
      expect($stderr).to receive(:flush).ordered
      expect(launcher).to receive(:exit!).with(75).ordered
      launcher.send(:flush_and_exit!, 75)
    end

    it 'names the generation of a mold promoted from a child the parent forked after the last generation' do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      launcher.instance_variable_set(:@mold_pipes, instance_double(Delayed::Launcher::Mold::Pipes, :report => nil))
      launcher.instance_variable_set(:@known_generation, 2) # Set by #fork_worker from the supervisor.
      allow(Delayed::Worker).to receive(:before_fork)
      info = nil
      allow(launcher).to receive(:fork) { |&block| block.call || 4321 }
      allow(launcher).to receive(:run_mold) { |_, mold_info, _| info = mold_info and nil }
      launcher.send(:fork_mold, 'delayed_job.1')
      expect(info[:generation]).to eq 3
    end

    it 'forks no mold from a promoted child whose parent died while it drained (status 75)' do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      launcher.instance_variable_set(:@supervisor_pid, -1) # Re-parented: the parent is gone.
      allow(launcher).to receive(:logger).and_return(Logger.new(nil))
      dispatcher = instance_double(Delayed::Dispatcher, :promoted? => true)
      expect(launcher).not_to receive(:fork_mold)
      expect(launcher).to receive(:flush_and_exit!).with(Delayed::Launcher::Mold::PROMOTION_FAILED)
      launcher.send(:promote_to_mold, 'delayed_job.0', dispatcher)
    end

    it 'forks even one process' do
      expect(Delayed::Launcher::Forking.new(:mold => true).send(:forking?)).to be true
      expect(Delayed::Launcher::Forking.new({}).send(:forking?)).to be false
    end
  end

  describe Delayed::Dispatcher do
    let(:log) { Concurrent::Array.new }

    before do
      Delayed::Job.delete_all
      GateJob.reset
    end

    it 'counts jobs performed, never reset by the stats report' do
      Delayed::Worker.exit_on_complete = true
      3.times { |i| Delayed::Job.enqueue(SimpleJob.new, :priority => i) }
      dispatcher = described_class.new(:sleep_delay => 0.01)
      capture_say(log, *and_workers(dispatcher))
      dispatcher.run
      expect(dispatcher.jobs_performed).to eq 3
    ensure
      Delayed::Worker.exit_on_complete = nil
    end

    it 'promotes by stopping: queued jobs are released, running jobs finish' do
      jobs = Array.new(3) { |i| Delayed::Job.enqueue(GateJob.new(i, true)) }
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('jobs_released.delayed_job') { |*, payload| events << payload }
      dispatcher = described_class.new(:threads => 1, :prefetch => 2, :sleep_delay => 0.01)
      capture_say(log, *and_workers(dispatcher))
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(10) { GateJob.started.pop }
      Timeout.timeout(10) { sleep 0.01 until Delayed::Job.where.not(:locked_by => nil).count == 3 } if Delayed::Job.respond_to?(:where)
      dispatcher.promote
      expect(dispatcher).to be_promoted
      GateJob.release = true
      Timeout.timeout(10) { thread.join }

      expect(dispatcher.jobs_performed).to eq 1
      expect(events.map { |e| e[:reason] }).to include 'promotion'
      expect(log.join("\n")).to include 'queued job(s) on promotion to mold'
      expect(jobs.drop(1).map { |job| Delayed::Job.find(job.id).locked_by }).to all(be_nil)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      Delayed::Worker.prefetch = 0
    end

    it 'reports a clean stop only once no thread is left running' do
      dispatcher = described_class.new
      expect(dispatcher).to be_cleanly_stopped
      dispatcher.instance_variable_set(:@threads, [Thread.new { sleep 5 }])
      expect(dispatcher).not_to be_cleanly_stopped
    ensure
      dispatcher.instance_variable_get(:@threads).each(&:kill)
    end

    it 'cancels a promotion when its parent is gone' do
      dispatcher = described_class.new(:supervisor_pid => [-1, -2])
      capture_say(log, *and_workers(dispatcher))
      dispatcher.promote
      expect(dispatcher.send(:supervisor_gone?)).to be true
      expect(dispatcher).not_to be_promoted
    end

    it 'accepts any of several parents' do
      dispatcher = described_class.new(:supervisor_pid => [-1, Process.ppid])
      expect(dispatcher.send(:supervisor_gone?)).to be false
    end

    it "shows 'promoting' in the process title while a promoted child finishes its jobs" do
      dispatcher = described_class.new(:procline => 'delayed_job.1')
      dispatcher.promote
      expect(dispatcher.procline).to start_with 'delayed_job.1: promoting, '
    end

    it 'reports a promotion cancelled by a signal' do
      dispatcher = described_class.new
      expect(dispatcher).not_to be_promotion_cancelled
      dispatcher.promote
      expect(dispatcher).not_to be_promotion_cancelled
      dispatcher.send(:handle_pending_signal, 'TERM')
      expect(dispatcher).to be_promotion_cancelled
    end

    it 'does not promote once stopping, and a stop signal cancels a promotion' do
      dispatcher = described_class.new
      dispatcher.stop
      dispatcher.promote
      expect(dispatcher).not_to be_promoted

      dispatcher = described_class.new
      dispatcher.promote
      dispatcher.send(:handle_pending_signal, 'TERM')
      expect(dispatcher).not_to be_promoted
    end
  end

  describe Delayed::ReportedStatus do
    it 'reads like Process::Status' do
      exited = described_class.new(10, 3, nil)
      killed = described_class.new(11, nil, 9)
      unknown = described_class.new(12, nil, nil)

      expect([exited.success?, exited.signaled?, exited.exitstatus, exited.to_s]).to eq [false, false, 3, 'pid 10 exit 3']
      expect([killed.success?, killed.signaled?, killed.termsig, killed.to_s]).to eq [false, true, 9, 'pid 11 SIGKILL (signal 9)']
      expect(described_class.new(13, 0, nil)).to be_success
      expect(unknown.to_s).to eq 'pid 12 exit unknown'
    end

    it 'gives ProcessExitError a reason' do
      expect(Delayed::ProcessExitError.new('delayed_job.1', 10, described_class.new(10, 3, nil)).message).
        to eq 'Child process delayed_job.1 (pid 10) exited with status 3'
      expect(Delayed::ProcessExitError.new('delayed_job.1', 11, described_class.new(11, nil, 9)).message).
        to eq 'Child process delayed_job.1 (pid 11) was killed by signal 9'
      expect(Delayed::ProcessExitError.new('delayed_job.1', 12, described_class.new(12, nil, nil)).message).
        to eq 'Child process delayed_job.1 (pid 12) exited (status unknown: its mold died first)'
    end
  end

  it 'encodes fork records in a fixed size' do
    record = [7, Delayed::Launcher::Mold::NO_POOL, 3].pack(Delayed::Launcher::Mold::FORK_RECORD)
    expect(record.bytesize).to eq Delayed::Launcher::Mold::FORK_RECORD_BYTES
    expect(record.unpack(Delayed::Launcher::Mold::FORK_RECORD)).to eq [7, Delayed::Launcher::Mold::NO_POOL, 3]
  end

  describe Delayed::ProcessUtil do
    it 'counts an unreaped zombie as gone', :fork do
      pid = fork { exit!(0) }
      sleep 0.05 until described_class.zombie?(pid) || !RUBY_PLATFORM.include?('linux')
      expect(described_class.alive?(pid)).to be false
    ensure
      Process.wait(pid) if pid
    end

    it 'counts a running process as alive, and a missing one as gone' do
      expect(described_class.alive?(Process.pid)).to be true
      expect(described_class.alive?(2**22 + 12_345)).to be false
    end

    it 'reads PSS on Linux' do
      skip 'Linux only' unless File.exist?('/proc/self/smaps_rollup')
      expect(described_class.pss_kb(Process.pid)).to be > 0
    end
  end

  describe 'fork safety' do
    after { Delayed::Worker.instance_variable_set(:@fork_unsafe, nil) }

    it 'is safe until a job says otherwise' do
      expect(Delayed::Worker).to be_fork_safe
      Delayed::Worker.no_longer_fork_safe!
      expect(Delayed::Worker).not_to be_fork_safe
    end
  end

  describe Delayed::Launcher::MoldSupervisor do
    # A stand-in for the forking launcher: records what the supervisor asks.
    let(:launcher) do
      Class.new do
        attr_reader :workers, :started, :exits, :logged
        attr_accessor :stopped

        def initialize
          @workers = {}
          @started = []
          @exits = []
          @logged = []
          @stopped = false
        end

        def stopped?
          @stopped
        end

        def stopping?
          @stopped
        end

        def pools; end

        def shutdown_timeout; end

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
        end

        def handle_exit(pid, status)
          @exits << [pid, status]
          @workers.delete(pid)
        end
      end.new
    end
    let(:pipes) { instance_double(Delayed::Launcher::Mold::Pipes, :request_fork => nil, :drain_fork_requests => nil) }
    let(:supervisor) { described_class.new(launcher, [5], pipes, true) }
    let(:signals) { [] }

    before { allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] } }

    def boot(pid, spawn = {})
      launcher.workers[pid] = ["delayed_job.#{pid}", {}]
      supervisor.child_started(pid, spawn)
      supervisor.send(:handle_status, 'b', pid)
    end

    def status(success)
      instance_double(Process::Status, :success? => success, :to_s => success ? 'exit 0' : 'exit 1')
    end

    it 'promotes the busiest idle child once past the threshold, and activates only its mold' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 11, 3, 1, 0)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      expect(signals).to include ['URG', 10]

      supervisor.send(:handle_status, 'm', 900, 99) # Not this promotion's.
      expect(signals).to include ['KILL', 900]
      supervisor.send(:handle_status, 'm', 901, 10) # Ready before its "M".
      supervisor.send(:handle_status, 'M', 10, 901)
      expect(signals).not_to include ['KILL', 901]
      expect(supervisor.generation).to eq 1
    end

    it 'never promotes a child that is no longer fork safe' do
      boot(10)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 1)
      expect(signals).not_to include ['URG', 10]
    end

    it 'retries a failed promotion after a back-off, keeping the threshold' do
      described_class.retry_delay_unit = 0
      boot(10)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      expect(supervisor.child_exited(10, status(false), {})).to be false
      expect(launcher.logged.join).to include 'promoting a new mold in 0s'
      boot(11)
      supervisor.send(:handle_status, 'p', 11, 6, 0, 0)
      expect(signals).to include ['URG', 11]
    ensure
      described_class.retry_delay_unit = 10
    end

    it 'keeps the old child when its refork replacement dies before booting' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      expect(supervisor.child_exited(10, status(true), {})).to be true
      supervisor.send(:advance_refork)
      expect(launcher.started).to include [:add, {}, 11]
      supervisor.child_started(20, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
      expect(supervisor.child_exited(20, status(false), {})).to be true
      expect(launcher.logged.join).to include 'died before booting; keeping pid 11'
      expect(signals).not_to include ['TERM', 11]
    end

    it 'stops the old child once its replacement boots' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      supervisor.send(:advance_refork)
      launcher.workers[20] = ['delayed_job.20', {}]
      supervisor.child_started(20, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
      supervisor.send(:handle_status, 'b', 20)
      expect(signals).to include ['TERM', 11]
    end

    it 'ignores an exit report from a mold that did not fork that child' do
      boot(10, :mold_pid => 900)
      supervisor.send(:handle_status, 'x', 901, 10, 0, nil)
      expect(launcher.exits).to be_empty
      supervisor.send(:handle_status, 'x', 900, 10, 0, nil)
      expect(launcher.exits.map(&:first)).to eq [10]
    end

    it 'forks a child itself when the mold fails to' do
      supervisor.instance_variable_get(:@pending_forks)[4] = {:options => {}, :spawn => {}, :at => 0}
      supervisor.send(:handle_status, 'e', 900, 4, 11)
      expect(launcher.started).to include [:start, 4, {}, {:generation => nil}]
    end

    it 'kills a child process that does not boot in time' do
      described_class.boot_timeout = 0
      launcher.workers[10] = ['delayed_job.10', {}]
      supervisor.child_started(10, :mold_pid => 900)
      supervisor.send(:check_boot_timeouts)
      expect(signals).to include ['KILL', 10]
    ensure
      described_class.boot_timeout = 60
    end

    it "refills a draining promoted child's slot after the deadline, without replacing it again" do
      described_class.drain_deadline = 0
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:check_promotion)
      expect(launcher.started).to include [:add, {}, 10]
      expect(launcher.logged.join).to include 'promoted to mold still has jobs running after 0s; refilling its slot. ' \
                                              'The promotion waits for them (up to their max_run_time, or shutdown_timeout if set)'
      expect(supervisor.child_exited(10, status(true), {})).to be true
    ensure
      described_class.drain_deadline = 300
    end

    it 'treats a mold that keeps failing to start children as broken and promotes a new one' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      3.times { |i| supervisor.child_started(30 + i, :mold_pid => 900, :generation => 1) }
      3.times { |i| supervisor.child_exited(30 + i, status(false), {}) }
      expect(signals).to include ['KILL', 900]
      expect(supervisor).not_to be_forking_from_mold
      expect(launcher.logged.join).to include 'Lost mold (pid 900); promoting a new mold in'
    end

    it "names each failure in the circuit breaker's message, telling app errors from mold faults" do
      described_class.boot_timeout = 0
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      supervisor.child_started(30, :mold_pid => 900, :generation => 1)
      supervisor.child_exited(30, Delayed::ReportedStatus.new(30, 1, nil), {})
      supervisor.child_started(31, :mold_pid => 900, :generation => 1)
      supervisor.send(:check_boot_timeouts)
      supervisor.child_exited(31, Delayed::ReportedStatus.new(31, nil, 9), {})
      supervisor.instance_variable_get(:@pending_forks)[4] = {:options => {}, :spawn => {:generation => 1}, :sent => 0}
      supervisor.send(:handle_status, 'e', 900, 4, Errno::EAGAIN::Errno)
      expect(launcher.logged.join("\n")).to include '3 child processes forked by mold (pid 900) failed to start in a row ' \
                                                    "(pid 30 exit 1, pid 31 boot timeout, fork failed (errno #{Errno::EAGAIN::Errno})); stopping it"
    ensure
      described_class.boot_timeout = 60
    end

    it 'forks the pending children itself when the mold dies' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      supervisor.request_fork(7, {}, {:generation => 1})
      expect(supervisor.reaped(900)).to be true
      expect(launcher.started).to include [:start, 7, {}, {:generation => nil}]
      expect(supervisor).not_to be_forking_from_mold
      expect(launcher.logged.join).to include 'promoting a new mold in'
    end

    it 'forgets an early boot when its exit is reported for a child never recorded' do
      supervisor.send(:handle_status, 'b', 50)
      supervisor.send(:handle_status, 'x', 900, 50, 0, nil)
      expect(supervisor.instance_variable_get(:@early_boots)).to be_empty
    end

    it 'skips a malformed status line' do
      supervisor.send(:handle_status, 'p', 10)
      supervisor.send(:handle_status, 'b', 'x')
      supervisor.send(:handle_status, 'm', 5)
      expect(launcher.logged.join).to include 'Ignoring malformed mold status line'
    end

    it "doesn't refill a refilled promoted child's slot again when it exits" do
      described_class.drain_deadline = 0
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:check_promotion)
      supervisor.send(:check_promotion)
      expect(launcher.started.count { |kind, _, pid| kind == :add && pid == 10 }).to eq 1
    ensure
      described_class.drain_deadline = 300
    end

    it 'kills molds still running once stopped with no child process left' do
      stub_const("#{described_class}::MOLD_STOP_TIMEOUT", 0)
      supervisor.instance_variable_get(:@molds)[900] = :active
      launcher.stopped = true
      supervisor.send(:stop_lingering_molds)
      supervisor.send(:stop_lingering_molds)
      expect(signals).to include ['KILL', 900]
    end

    describe 'failure events' do
      let(:events) { [] }

      around do |example|
        subscriber = ActiveSupport::Notifications.subscribe(/\Amold_|\Athread_error/) { |name, *, payload| events << [name.split('.').first, payload] }
        example.run
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      def payloads(name)
        events.select { |event, _| event == name }.map(&:last)
      end

      def activate_mold(pid = 900)
        boot(10)
        boot(11)
        supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
        supervisor.send(:handle_status, 'M', 10, pid)
        supervisor.send(:handle_status, 'm', pid, 10)
      end

      it 'publishes mold_activated with whether the parent is a subreaper' do
        activate_mold
        expect(payloads('mold_activated').first).to include(:pid => 900, :generation => 1, :subreaper => true)
      end

      it 'publishes mold_lost when the active mold exits' do
        activate_mold
        supervisor.reaped(900)
        expect(payloads('mold_lost')).to eq [{:pid => 900, :generation => 1, :reason => :exited, :retry_in => 10}]
      end

      it 'publishes mold_lost when the mold is broken' do
        activate_mold
        3.times { |i| supervisor.child_started(30 + i, :mold_pid => 900, :generation => 1) }
        3.times { |i| supervisor.child_exited(30 + i, status(false), {}) }
        expect(payloads('mold_lost').map { |p| p[:reason] }).to eq [:broken]
      end

      it 'publishes mold_lost when the mold hangs on a fork' do
        stub_const("#{described_class}::MOLD_FORK_TIMEOUT", 0)
        activate_mold
        supervisor.request_fork(7, {}, {:generation => 1})
        supervisor.send(:check_pending_forks)
        expect(payloads('mold_lost').map { |p| p[:reason] }).to eq [:hung]
        expect(signals).to include ['KILL', 900]
      end

      it "doesn't publish mold_lost for a mold exiting during shutdown" do
        activate_mold
        launcher.stopped = true
        supervisor.reaped(900)
        expect(payloads('mold_lost')).to be_empty
      end

      it 'publishes mold_promotion_failed when the promoted child forks no mold, with a growing retry delay' do
        described_class.retry_delay_unit = 1
        boot(10)
        boot(11)
        supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
        supervisor.child_exited(10, status(false), {})
        supervisor.instance_variable_set(:@hold_until, nil)
        supervisor.send(:handle_status, 'p', 11, 6, 0, 0)
        supervisor.child_exited(11, status(false), {})
        expect(payloads('mold_promotion_failed')).to eq [
          {:pid => 10, :mold_pid => nil, :trigger => :threshold, :reason => :child_exited, :retry_in => 1},
          {:pid => 11, :mold_pid => nil, :trigger => :threshold, :reason => :child_exited, :retry_in => 2}
        ]
      ensure
        described_class.retry_delay_unit = 10
      end

      it 'publishes mold_promotion_failed when the mold exits before it is ready' do
        boot(10)
        boot(11)
        supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
        supervisor.send(:handle_status, 'M', 10, 900)
        supervisor.reaped(900)
        expect(payloads('mold_promotion_failed').first).to include(:pid => 10, :mold_pid => 900, :reason => :mold_exited)
      end

      it 'publishes mold_promotion_failed when no mold becomes ready in time' do
        stub_const("#{described_class}::PROMOTION_FORK_TIMEOUT", 0)
        boot(10)
        boot(11)
        supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
        supervisor.child_exited(10, status(true), {})
        supervisor.send(:check_promotion)
        expect(payloads('mold_promotion_failed').first).to include(:pid => 10, :reason => :timeout)
      end

      it 'publishes thread_error (Mold forking) when the mold fails to fork a child' do
        supervisor.instance_variable_get(:@pending_forks)[4] = {:options => {}, :spawn => {}, :at => 0}
        supervisor.send(:handle_status, 'e', 900, 4, Errno::EAGAIN::Errno)
        error = payloads('thread_error').first
        expect(error).to include(:context => 'Mold forking', :worker => 'delayed_job.4', :pid => 900)
        expect(error[:error]).to be_a(Errno::EAGAIN)
      end
    end

    describe Delayed::LogSubscriber do
      let(:lines) { [] }

      before do
        log = lines
        logger = Object.new
        %i(info warn error debug).each { |m| logger.define_singleton_method(m) { |*, &block| log << block.call } }
        allow_any_instance_of(described_class).to receive(:logger).and_return(logger)
      end

      def event(payload)
        instance_double(ActiveSupport::Notifications::Event, :payload => payload)
      end

      it 'logs mold failures' do
        subscriber = described_class.new
        subscriber.mold_lost(event(:pid => 900, :reason => :exited, :generation => 2, :retry_in => 10))
        subscriber.mold_promotion_failed(event(:pid => 10, :reason => :timeout, :retry_in => 20))
        expect(lines).to eq ['Mold (pid 900) lost (exited), generation 2; promoting a new mold in 10s',
                             'Promotion of child process (pid 10) to mold failed (timeout); retrying in 20s']
      end
    end

    it 'only times out the boot of children forked by a mold' do
      described_class.boot_timeout = 0
      launcher.workers[10] = ['delayed_job.10', {}]
      supervisor.child_started(10, {})
      supervisor.child_started(11, :mold_pid => 900, :generation => 0)
      supervisor.send(:check_boot_timeouts)
      expect(signals).to eq [['KILL', 11]]
    ensure
      described_class.boot_timeout = 60
    end

    it 'reforks from the mold a child the parent forked when the mold could not' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.send(:handle_status, 'M', 10, 900)
      supervisor.send(:handle_status, 'm', 900, 10)
      supervisor.instance_variable_get(:@pending_forks)[4] = {:options => {}, :spawn => {:generation => 1}, :at => 0}
      supervisor.send(:handle_status, 'e', 900, 4, 11)
      expect(launcher.started).to include [:start, 4, {}, {:generation => nil}]
      launcher.workers[40] = ['delayed_job.40', {}]
      supervisor.child_started(40, :generation => nil)
      supervisor.send(:handle_status, 'b', 40)
      supervisor.send(:advance_refork)
      expect(launcher.started).to include [:add, {}, 40]
    end

    describe 'hardening' do
      def activate_mold(pid = 900)
        boot(10)
        boot(11)
        supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
        supervisor.send(:handle_status, 'M', 10, pid)
        supervisor.send(:handle_status, 'm', pid, 10)
      end

      it "adopts a booted child whose mold's \"f\" never came, and ignores a late \"f\"" do
        activate_mold
        supervisor.request_fork(7, {}, {:generation => 1})
        supervisor.send(:handle_status, 'b', 70, 7, 900)
        expect(launcher.workers).to have_key(70)
        supervisor.send(:handle_status, 'f', 900, 70, 7)
        expect(signals).not_to include ['TERM', 70]
        expect(launcher.started.count { |kind, pid| kind == :child && pid == 70 }).to eq 1
      end

      it 'stops a booted child whose slot is no longer pending' do
        activate_mold
        supervisor.send(:handle_status, 'b', 70, 7, 900)
        expect(signals).to include ['TERM', 70]
        expect(launcher.workers).not_to have_key(70)
      end

      it 'reports a child gone once its mold died without reporting its exit (subreaper)' do
        activate_mold
        supervisor.child_started(70, :mold_pid => 900, :generation => 1)
        allow(Delayed::ProcessUtil).to receive(:exists?).and_call_original
        allow(Delayed::ProcessUtil).to receive(:exists?).with(70).and_return(false)
        supervisor.reaped(900)
        supervisor.send(:check_orphans)
        expect(launcher.exits.map(&:first)).to include 70
      end

      it "doesn't fork a replacement for a refork step aborted by the circuit breaker" do
        activate_mold
        launcher.workers[11] = ['delayed_job.11', {}]
        supervisor.send(:advance_refork)
        index = launcher.started.find { |kind, _, pid| kind == :add && pid == 11 } && 20
        supervisor.instance_variable_get(:@pending_forks)[index] = {:options => {}, :spawn => {:replaces_pid => 11, :generation => 1}, :sent => 0}
        supervisor.instance_variable_set(:@boot_failures, ['pid 1 exit 1', 'pid 2 exit 1'])
        supervisor.send(:handle_status, 'e', 900, index, 12)
        expect(launcher.started).not_to include [:start, index, {}, {:replaces_pid => 11, :generation => nil}]
        expect(supervisor.replacement_needed?(11)).to be false
      end

      it 'drops a stale retry once a mold activates' do
        activate_mold(900)
        supervisor.request_promotion
        supervisor.send(:handle_promotion_requests) # Ignored: refork in progress.
        supervisor.instance_variable_set(:@steps, {})
        supervisor.instance_variable_get(:@children).each_value { |info| info.generation = 1 }
        supervisor.instance_variable_set(:@retry_trigger, :mold_lost)
        boot(12, :mold_pid => 900, :generation => 1)
        supervisor.send(:promote, :signal)
        promoted = signals.reverse.find { |signal, _| signal == 'URG' }.last
        supervisor.send(:handle_status, 'M', promoted, 901)
        supervisor.send(:handle_status, 'm', 901, promoted)
        expect(supervisor.instance_variable_get(:@retry_trigger)).to be_nil
      end

      it "doesn't remember a reaped child process as a reaped mold" do
        launcher.workers[10] = ['delayed_job.10', {}]
        supervisor.reaped(10)
        expect(supervisor.instance_variable_get(:@reaped)).not_to have_key(10)
      end

      it 'replaces a mold stopped by a signal sent to it alone' do
        activate_mold
        supervisor.send(:handle_status, 's', 900)
        expect(supervisor).not_to be_forking_from_mold
        expect(launcher.logged.join).to include 'was stopped by a signal'
      end

      it "records a child forked by a mold that isn't active as of no generation" do
        activate_mold
        supervisor.child_started(70, :mold_pid => 800, :generation => 1)
        expect(supervisor.instance_variable_get(:@children)[70].generation).to be_nil
      end

      it 'stops promoting after MAX_FAILURES in a row, until SIGURG' do
        described_class.retry_delay_unit = 0
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('mold_disabled.delayed_job') { |*, payload| events << payload }
        boot(10)
        described_class::MAX_FAILURES.times do |i|
          boot(20 + i)
          supervisor.instance_variable_set(:@hold_until, nil)
          supervisor.send(:handle_status, 'p', 20 + i, 6, 0, 0)
          supervisor.child_exited(20 + i, status(false), {})
        end
        expect(events).to eq [{:failures => described_class::MAX_FAILURES}]
        urgs = signals.count { |signal, _| signal == 'URG' }
        supervisor.send(:handle_status, 'p', 10, 60, 0, 0)
        expect(signals.count { |signal, _| signal == 'URG' }).to eq urgs
        supervisor.request_promotion
        supervisor.send(:handle_promotion_requests)
        expect(signals.count { |signal, _| signal == 'URG' }).to eq urgs + 1
      ensure
        described_class.retry_delay_unit = 10
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      it 'holds fork requests while a promoted mold is not yet ready' do
        activate_mold(900)
        boot(12, :mold_pid => 900, :generation => 1)
        supervisor.instance_variable_set(:@steps, {})
        supervisor.instance_variable_get(:@children).each_value { |info| info.generation = 1 }
        supervisor.send(:promote, :signal)
        promoted = signals.reverse.find { |signal, _| signal == 'URG' }.last
        supervisor.send(:handle_status, 'M', promoted, 901)
        supervisor.request_fork(30, {}, {:generation => 1})
        expect(pipes).not_to have_received(:request_fork).with(30, anything, anything)
        supervisor.send(:handle_status, 'm', 901, promoted)
        supervisor.send(:send_fork_requests)
        expect(pipes).to have_received(:request_fork).with(30, anything, 2) # The new mold's generation.
      end

      it "ignores an \"s\" from a mold that isn't active, or once stopping" do
        activate_mold(900)
        supervisor.send(:handle_status, 's', 901)
        expect(supervisor).to be_forking_from_mold
        launcher.stopped = true
        supervisor.send(:handle_status, 's', 900)
        expect(launcher.logged.join).not_to include 'was stopped by a signal'
      end

      it 'stops a child booting while stopping, its slot no longer pending' do
        activate_mold
        supervisor.request_fork(7, {}, {:generation => 1})
        launcher.stopped = true
        allow(pipes).to receive(:each_status)
        supervisor.tick # Drops pending forks while stopping.
        supervisor.send(:handle_status, 'b', 70, 7, 900)
        expect(signals).to include ['TERM', 70]
        expect(launcher.workers).not_to have_key(70)
      end

      it 'stops an early boot never reported once the boot timeout passes, if still running' do
        described_class.boot_timeout = 0
        supervisor.send(:handle_status, 'b', 70)
        supervisor.send(:handle_status, 'b', 71)
        allow(Delayed::ProcessUtil).to receive(:alive?).with(70).and_return(true)
        allow(Delayed::ProcessUtil).to receive(:alive?).with(71).and_return(false)
        supervisor.send(:expire_early_boots)
        expect(signals).to eq [['TERM', 70]]
        expect(supervisor.instance_variable_get(:@early_boots)).to be_empty
      ensure
        described_class.boot_timeout = 60
      end

      it 'holds fork requests while a killed (abandoned) mold may still run, then forks from the parent' do
        stub_const("#{described_class}::MOLD_FORK_TIMEOUT", 0)
        activate_mold(900)
        supervisor.request_fork(7, {}, {:generation => 1})
        supervisor.send(:check_pending_forks) # Hung: abandoned and killed.
        expect(supervisor.instance_variable_get(:@molds)[900]).to eq :abandoned
        expect(launcher.started).to include [:start, 7, {}, {:generation => nil}]
        supervisor.instance_variable_get(:@pending_forks)[8] = {:options => {}, :spawn => {:generation => 1}}
        supervisor.send(:send_fork_requests)
        expect(pipes).not_to have_received(:request_fork).with(8, anything, anything)
        supervisor.reaped(900)
        supervisor.send(:send_fork_requests)
        expect(pipes).to have_received(:request_fork).with(8, anything, 1)
      end

      it 'measures PSS before promotion, with the promoted child still running' do
        allow(Delayed::ProcessUtil).to receive(:pss_kb).and_return(1024)
        activate_mold
        expect(launcher.logged.join).to include 'PSS 2 MB'
      end
    end

    it 'ignores SIGURG during a promotion' do
      boot(10)
      boot(11)
      supervisor.send(:handle_status, 'p', 10, 6, 0, 0)
      supervisor.request_promotion
      supervisor.send(:handle_promotion_requests)
      expect(signals.count { |signal, _| signal == 'URG' }).to eq 1
      expect(launcher.logged.join).to include 'ignoring it'
    end
  end
end
