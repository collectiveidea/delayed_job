require 'helper'

# The mold process lifecycle crossed with signals and process death, at unit
# level: the shutdown timeout's kill reaching molds in each role, the
# promoted child killed while stopping, and SIGURG after a lost mold. The
# process level is in spec/processes/mold_signal_race_spec.rb.
describe 'Mold process signal races' do
  # A stand-in for the forking launcher: records what the supervisor asks.
  let(:launcher_class) do
    Class.new do
      attr_reader :workers, :started, :exits, :logged
      attr_accessor :stopped, :pools, :shutdown_timeout

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
    end
  end

  describe Delayed::Launcher::MoldSupervisor do
    let(:launcher) { launcher_class.new }
    let(:pipes) { instance_double(Delayed::Launcher::Mold::Pipes, :request_fork => nil, :drain_fork_requests => nil, :each_status => nil) }
    let(:reaps_orphans) { true }
    let(:supervisor) { described_class.new(launcher, [5], pipes, reaps_orphans) }
    let(:signals) { [] }
    let(:clock) { [0.0] }

    before do
      allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] }
      allow(Process).to(receive(:clock_gettime).and_wrap_original { |original, *args| original.call(*args) + clock[0] })
    end

    def travel(seconds)
      clock[0] += seconds
    end

    def line(type, *args)
      supervisor.send(:handle_status, type, *args)
    end

    def boot(pid, spawn = {})
      launcher.workers[pid] = ["delayed_job.#{pid}", {}]
      supervisor.child_started(pid, spawn)
      line('b', pid)
    end

    def reported(pid, exitstatus, termsig = nil)
      Delayed::ReportedStatus.new(pid, exitstatus, termsig)
    end

    def logged
      launcher.logged.join("\n")
    end

    def sent(signal)
      signals.select { |sig, _| sig == signal }.map(&:last)
    end

    def molds
      supervisor.instance_variable_get(:@molds)
    end

    # Promotes `pid` on SIGURG; its mold `mold` reports "M" and, if
    # `ready`, "m", the promoted child having exited cleanly.
    def promote_on_signal(pid, mold, ready: true)
      supervisor.request_promotion
      supervisor.send(:handle_promotion_requests)
      expect(sent('URG').last).to eq pid
      line('M', pid, mold)
      return unless ready
      line('m', mold, pid)
      supervisor.child_exited(pid, reported(pid, 0), {})
      launcher.workers.delete(pid)
    end

    # Mold 900 retired, 901 active (generation 2) and 902 promoted from
    # child 30, not yet ready.
    def molds_in_every_role
      boot(10)
      line('p', 10, 6, 0, 0)
      line('M', 10, 900)
      line('m', 900, 10)
      supervisor.child_exited(10, reported(10, 0), {})
      launcher.workers.delete(10)
      boot(20, :mold_pid => 900, :generation => 1)
      promote_on_signal(20, 901)
      boot(30, :mold_pid => 901, :generation => 2)
      promote_on_signal(30, 902, :ready => false)
      expect(molds).to eq(900 => :retired, 901 => :active, 902 => :promoted)
    end

    # The shutdown timeout's kill signals the molds the supervisor knows,
    # whatever their role: one left out would keep the pidfile locked.
    it 'signals every mold on a kill: retired, active, and promoted but not ready' do
      molds_in_every_role
      signals.clear
      launcher.stopped = true
      supervisor.signal_molds('KILL')

      expect(sent('KILL')).to contain_exactly(900, 901, 902)
    end

    # The promoted child SIGKILLed by the kill, its mold not ready: the
    # promotion fails without a retry, the mold is killed (again), and
    # nothing is forked while the molds die one by one.
    it 'plans nothing when the promoted child and every mold die from the kill, done once each is reaped' do
      molds_in_every_role
      launcher.stopped = true
      supervisor.signal_molds('KILL')
      started = launcher.started.dup
      expect(supervisor.child_exited(30, reported(30, nil, 9), {})).to be false
      expect(supervisor.reaped(901)).to be true
      expect(supervisor.reaped(900)).to be true
      expect(supervisor).not_to be_done
      expect(supervisor.reaped(902)).to be true
      travel(described_class::MOLD_READY_TIMEOUT + 1)
      supervisor.tick

      expect(supervisor).to be_done
      expect(launcher.started).to eq started
      expect(logged).not_to match(/promoting a new mold|Lost mold|forking child processes from the parent/)
      expect(supervisor.generation).to eq 2
    end

    # A late "m" from the killed promoted mold, read after it was reaped,
    # must not activate it or leave anything to wait for.
    it 'ignores an "m" read after the kill reaped the promoted mold' do
      molds_in_every_role
      launcher.stopped = true
      supervisor.child_exited(30, reported(30, 0), {})
      [900, 901, 902].each { |mold| supervisor.reaped(mold) }
      line('m', 902, 30)

      expect(supervisor.generation).to eq 2
      expect(supervisor).not_to be_forking_from_mold
      expect(supervisor).to be_done
    end

    # README: SIGURG promotes at once, "skipping any retry back-off".
    it 'promotes at once on SIGURG during the back-off of a failed promotion' do
      boot(10)
      boot(11)
      line('p', 10, 6, 0, 0)
      supervisor.child_exited(10, reported(10, Delayed::Launcher::Mold::PROMOTION_FAILED), {})
      launcher.workers.delete(10)
      expect(logged).to include 'promoting a new mold in 10s'
      supervisor.request_promotion
      supervisor.tick

      expect(sent('URG')).to eq [10, 11]
      expect(logged).to include 'to mold after 0 job(s) (signal)'
    end

    # The mold is lost mid-refork, so the children not yet reforked stay of
    # the previous generation; nothing reforks them until a new mold is
    # ready. SIGURG must still promote (or re-arm once disabled), as no
    # refork is in progress.
    describe 'SIGURG after the active mold is lost mid-refork' do
      before do
        boot(10)
        boot(11)
        line('p', 10, 6, 0, 0)
        line('M', 10, 900)
        line('m', 900, 10)
        supervisor.child_exited(10, reported(10, 0), {})
        launcher.workers.delete(10)
        supervisor.tick # Starts reforking pid 11 (generation 0).
        expect(launcher.started).to include [:add, {}, 11]
      end

      it 'promotes at once during the retry back-off' do
        supervisor.reaped(900)
        expect(logged).to include 'Lost mold (pid 900); promoting a new mold in 10s'
        supervisor.request_promotion
        supervisor.tick

        expect(logged).not_to include 'ignoring it'
        expect(sent('URG')).to eq [10, 11]
      end

      it 're-arms promotion once disabled' do
        supervisor.instance_variable_set(:@failures, described_class::MAX_FAILURES - 1)
        supervisor.reaped(900)
        expect(logged).to include 'no more are tried'
        supervisor.request_promotion
        supervisor.tick

        expect(logged).to include 'Received SIGURG: promoting to mold again'
        expect(sent('URG')).to eq [10, 11]
      end
    end
  end
end
