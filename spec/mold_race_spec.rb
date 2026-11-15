require 'helper'

# Race conditions and edge cases of the mold process, at unit level: status
# lines out of order, signals and stops in each phase, failed promotions,
# thresholds, refork steps, the circuit breaker, pools, and the pipes
# protocol. The process level is in spec/processes/mold_race_spec.rb.
describe 'Mold process races' do
  # A stand-in for the forking launcher: records what the supervisor asks.
  # Like the real one, it reports children a mold forked back to the
  # supervisor (#child_started).
  let(:launcher_class) do
    Class.new do
      attr_reader :workers, :started, :exits, :logged
      attr_accessor :stopped, :pools, :supervisor

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
        supervisor&.child_started(pid, spawn)
      end

      def handle_exit(pid, status)
        @exits << [pid, status]
        @workers.delete(pid)
      end
    end
  end

  def reported(pid, exitstatus, termsig = nil)
    Delayed::ReportedStatus.new(pid, exitstatus, termsig)
  end

  describe Delayed::Launcher::MoldSupervisor do
    let(:launcher) { launcher_class.new }
    let(:pipes) { instance_double(Delayed::Launcher::Mold::Pipes, :request_fork => nil, :drain_fork_requests => nil, :each_status => nil) }
    let(:thresholds) { [5] }
    let(:reaps_orphans) { true }
    let(:supervisor) { described_class.new(launcher, thresholds, pipes, reaps_orphans).tap { |s| launcher.supervisor = s } }
    let(:signals) { [] }
    let(:clock) { [0.0] }

    before do
      allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] }
      # Monotonic time, moved forward by #travel.
      allow(Process).to(receive(:clock_gettime).and_wrap_original { |original, *args| original.call(*args) + clock[0] })
    end

    around do |example|
      settings = %i(boot_timeout retry_delay_unit drain_deadline).map { |setting| [setting, described_class.send(setting)] }
      example.run
    ensure
      settings.each { |setting, value| described_class.send("#{setting}=", value) }
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

    def ping(pid, jobs, busy = 0)
      line('p', pid, jobs, busy, 0)
    end

    def ok(pid)
      reported(pid, 0)
    end

    def logged
      launcher.logged.join("\n")
    end

    def sent(signal)
      signals.select { |sig, _| sig == signal }.map(&:last)
    end

    def adds
      launcher.started.select { |entry| entry.first == :add }
    end

    # Boots `others`, promotes `pid` past the threshold, and activates mold
    # `mold`, its promoted child having exited cleanly.
    def activate(pid = 10, mold = 900, others: [11])
      boot(pid)
      others.each { |other| boot(other) }
      ping(pid, 6)
      line('M', pid, mold)
      line('m', mold, pid)
      expect(supervisor.child_exited(pid, ok(pid), {})).to be true
    end

    describe 'status lines out of order' do
      it 'activates a mold whose "m" comes before its "M", the late "M" changing nothing' do
        boot(10)
        boot(11)
        ping(10, 6)
        line('m', 901, 10)
        line('M', 10, 901)

        expect(supervisor.generation).to eq 1
        expect(sent('KILL')).to be_empty
        expect(supervisor).to be_forking_from_mold
        # The promoted child's slot is refilled at once: its mold is ready.
        expect(supervisor.child_exited(10, ok(10), :queues => ['a'])).to be true
        expect(adds).to eq [[:add, {:queues => ['a']}, 10]]
      end

      it 'stops a child process the mold forks after the parent gave up on it (hung mold)' do
        activate
        supervisor.request_fork(7, {}, :generation => 1)
        line('b', 55) # Booted before its "f" is read.
        travel(described_class::MOLD_FORK_TIMEOUT + 1)
        supervisor.tick

        expect(sent('KILL')).to eq [900]
        expect(launcher.started).to include [:start, 7, {}, {:generation => nil}]
        expect(logged).to include "did not fork a child process within #{described_class::MOLD_FORK_TIMEOUT}s"
        line('f', 900, 55, 7)
        expect(sent('TERM')).to eq [55]
        expect(launcher.started.map(&:first)).not_to include :child
        expect(logged).to include 'Stopping child process (pid 55) forked by mold (pid 900) after the parent gave up on it'
      end

      it 'ignores an "e" for a fork the parent already gave up on' do
        activate
        supervisor.request_fork(7, {}, :generation => 1)
        supervisor.reaped(900) # Pending forks go to the parent.
        launcher.started.clear
        line('e', 900, 7, 11)
        expect(launcher.started).to be_empty
      end

      it 'completes a refork step when the replacement\'s "b" comes before its "f"' do
        activate
        supervisor.tick
        expect(adds).to include [:add, {}, 11]
        supervisor.request_fork(3, {}, :replaces_pid => 11, :generation => 1)
        line('b', 60)
        expect(sent('TERM')).to be_empty
        line('f', 900, 60, 3)

        expect(launcher.workers.keys).to include 60
        expect(sent('TERM')).to eq [11] # The replacement had booted already.
      end

      it 'ignores an "x" for a pid it never recorded' do
        activate
        line('x', 900, 4242, 0, nil)
        expect(launcher.exits).to be_empty
      end

      it 'ignores an "x" from a mold for a pid now held by a child the parent forked' do
        boot(10) # Forked by the parent: no mold.
        line('x', 900, 10, 1, nil)
        expect(launcher.exits).to be_empty
      end

      it 'returns false, not nil, from child_exited for a child process it does not take care of' do
        boot(10)
        expect(supervisor.child_exited(10, reported(10, 1), {})).to be false
      end

      it 'skips malformed lines' do
        boot(10)
        expect { line('b') }.not_to raise_error
        expect { line('b', nil) }.not_to raise_error
        expect { line('z', 10) }.not_to raise_error
        expect { line('p', 10) }.not_to raise_error # Too few arguments.
        expect { line('b', 10, 11, 12) }.not_to raise_error # Too many.
        expect { line('p', 10, nil, 0, 0) }.not_to raise_error # "-" for the job count.
        expect(logged).to include 'Ignoring malformed mold status line'
        expect(sent('URG')).to be_empty
      end

      it 'does not record a mold for an "M" whose mold pid is "-"' do
        boot(10)
        boot(11)
        ping(10, 6)
        line('M', 10, nil)
        expect(supervisor).to be_done
      end
    end

    describe 'SIGURG' do
      it 'promotes once for a burst of signals' do
        boot(10)
        boot(11)
        3.times { supervisor.request_promotion }
        supervisor.tick
        supervisor.tick
        expect(sent('URG').size).to eq 1
        expect(logged).to include '(signal)'
      end

      it 'is ignored during a refork' do
        activate
        supervisor.tick # Starts reforking pid 11.
        expect(adds).to include [:add, {}, 11]
        supervisor.request_promotion
        supervisor.tick
        expect(sent('URG')).to eq [10]
        expect(logged).to include 'while a promotion or refork is in progress; ignoring it'
      end

      it 'is ignored once stopping' do
        boot(10)
        launcher.stopped = true
        supervisor.request_promotion
        supervisor.tick
        expect(sent('URG')).to be_empty
      end

      it 'warns when no child process can be promoted' do
        supervisor.child_started(10, {}) # Not booted yet.
        supervisor.request_promotion
        supervisor.tick
        expect(sent('URG')).to be_empty
        expect(logged).to include 'No child process to promote to mold'
      end
    end

    describe 'stopping during a promotion' do
      before do
        boot(10)
        boot(11)
        ping(10, 6)
      end

      it 'kills the mold of a promoted child that stops before its "M", and refills nothing' do
        launcher.stopped = true
        line('M', 10, 901)
        line('m', 901, 10)
        expect(sent('KILL')).to eq [901, 901]
        expect(supervisor.generation).to eq 0
        expect(supervisor.child_exited(10, ok(10), {})).to be true
        expect(adds).to be_empty
        expect(supervisor).not_to be_done
        expect(supervisor.reaped(901)).to be true
        expect(supervisor).to be_done
      end

      it 'does not plan another promotion while stopping' do
        launcher.stopped = true
        line('M', 10, 901)
        supervisor.child_exited(10, ok(10), {})
        travel(described_class::PROMOTION_FORK_TIMEOUT + 1)
        supervisor.tick
        expect(logged).not_to include 'promoting a new mold'
      end

      it 'kills a mold that becomes ready between "M" and "m"' do
        line('M', 10, 901)
        launcher.stopped = true
        line('m', 901, 10)
        expect(sent('KILL')).to eq [901]
        expect(supervisor.generation).to eq 0
        expect(supervisor).not_to be_forking_from_mold
        expect(supervisor).not_to be_done
        supervisor.reaped(901)
        expect(supervisor).to be_done
      end
    end

    describe 'stopping mid-refork' do
      it 'drops pending forks, and is done once the mold exits' do
        activate
        supervisor.request_fork(3, {}, :replaces_pid => 11, :generation => 1)
        launcher.stopped = true
        supervisor.tick
        expect(pipes).to have_received(:drain_fork_requests)
        line('f', 900, 60, 3)
        expect(sent('TERM')).to eq [60]
        expect(supervisor).not_to be_done
        supervisor.reaped(900)
        expect(supervisor).to be_done
      end

      it 'kills a mold still running after the child processes have stopped' do
        activate
        launcher.workers.clear
        launcher.stopped = true
        supervisor.tick
        travel(described_class::MOLD_STOP_TIMEOUT - 1)
        supervisor.tick
        expect(sent('KILL')).to be_empty
        travel(2)
        supervisor.tick
        expect(sent('KILL')).to eq [900]
      end

      it 'forks pending children from the parent, without a retry, when the mold dies while stopping' do
        activate
        supervisor.request_fork(3, {}, :generation => 1)
        launcher.stopped = true
        supervisor.reaped(900)
        expect(launcher.started).to include [:start, 3, {}, {:generation => nil}]
        expect(logged).not_to include 'Lost mold'
      end
    end

    describe 'a failed promotion' do
      before do
        boot(10)
        boot(11)
        ping(10, 6)
      end

      it 'is retried after a back-off when the promoted child exits with 75' do
        expect(supervisor.child_exited(10, reported(10, Delayed::Launcher::Mold::PROMOTION_FAILED), {})).to be false
        expect(logged).to include 'promoted to mold exited with pid 10 exit 75, forking no mold; promoting a new mold in 10s'
        ping(11, 6)
        expect(sent('URG')).to eq [10] # Held.
        travel(11)
        ping(11, 6)
        expect(sent('URG')).to eq [10, 11]
      end

      it 'is retried when the promoted child is killed by a signal' do
        expect(supervisor.child_exited(10, reported(10, nil, 9), {})).to be false
        expect(logged).to include 'exited with pid 10 SIGKILL (signal 9), forking no mold'
        expect(supervisor.generation).to eq 0
      end

      it "refills the promoted child's slot when its mold dies before it is ready" do
        line('M', 10, 901)
        expect(supervisor.child_exited(10, ok(10), :queues => ['a'])).to be true
        expect(adds).to be_empty # Waits for the mold.
        expect(supervisor.reaped(901)).to be true
        expect(logged).to include 'Mold (pid 901) exited before it was ready'
        expect(adds).to eq [[:add, {:queues => ['a']}, 10]]
        expect(sent('KILL')).to be_empty # Already gone.
      end

      it 'refills the slot when no "M" comes in time' do
        supervisor.child_exited(10, ok(10), {})
        travel(described_class::PROMOTION_FORK_TIMEOUT - 1)
        supervisor.tick
        expect(adds).to be_empty
        travel(2)
        supervisor.tick
        expect(logged).to include 'promoted to mold, but no mold became ready'
        expect(adds).to eq [[:add, {}, 10]]
      end

      it 'kills a mold not ready in time, and ignores its late "m"' do
        line('M', 10, 901)
        supervisor.child_exited(10, ok(10), {})
        travel(described_class::MOLD_READY_TIMEOUT + 1)
        supervisor.tick
        expect(sent('KILL')).to eq [901]
        line('m', 901, 10)
        expect(supervisor.generation).to eq 0
        expect(supervisor).not_to be_forking_from_mold
      end

      it 'forgets a mold reaped before its "M" is read' do
        supervisor.child_exited(10, ok(10), {})
        expect(supervisor.reaped(901)).to be false # Unknown yet.
        line('M', 10, 901)
        travel(described_class::MOLD_READY_TIMEOUT + 1)
        supervisor.tick
        launcher.workers.clear
        launcher.stopped = true
        3.times do
          supervisor.tick
          travel(described_class::MOLD_STOP_TIMEOUT + 1)
        end
        expect(supervisor).to be_done
      end
    end

    describe 'an "m" read after its mold was reaped' do
      it 'leaves nothing to wait for at shutdown' do
        boot(10)
        boot(11)
        ping(10, 6)
        line('M', 10, 901)
        supervisor.child_exited(10, ok(10), {})
        supervisor.reaped(901) # Wrote "m", then died.
        line('m', 901, 10)
        expect(sent('KILL')).to be_empty # Gone: its pid may be reused.
        expect(supervisor).to be_done
      end
    end

    describe 'a promoted child whose slot was refilled while it drained' do
      before do
        described_class.drain_deadline = 1
        boot(10)
        boot(11)
        ping(10, 6)
        travel(2)
        supervisor.tick
        expect(adds).to eq [[:add, {}, 10]]
      end

      it 'is not replaced again when it exits' do
        expect(supervisor.child_exited(10, ok(10), {})).to be true
        expect(supervisor.child_exited(11, reported(11, 1), {})).to be_falsey
      end

      it 'lets a later promotion happen when it exits with 75' do
        supervisor.child_exited(10, reported(10, Delayed::Launcher::Mold::PROMOTION_FAILED), {})
        travel(described_class::MOLD_READY_TIMEOUT + described_class::MAX_RETRY_DELAY)
        supervisor.tick
        ping(11, 6)
        expect(sent('URG')).to eq [10, 11]
      end

      it 'lets a later promotion happen when it exits cleanly without forking a mold' do
        supervisor.child_exited(10, ok(10), {})
        travel(described_class::MOLD_READY_TIMEOUT + 1)
        supervisor.tick
        travel(described_class::MAX_RETRY_DELAY)
        ping(11, 6)
        expect(sent('URG')).to eq [10, 11]
      end
    end

    describe 'thresholds' do
      let(:thresholds) { [5, 10] }

      it 'advance only once a mold is activated' do
        boot(10)
        boot(11)
        ping(10, 6)
        supervisor.child_exited(10, reported(10, Delayed::Launcher::Mold::PROMOTION_FAILED), {})
        travel(11)
        ping(11, 5) # Still the first threshold.
        expect(sent('URG')).to eq [10, 11]
        line('M', 11, 901)
        line('m', 901, 11)
        supervisor.child_exited(11, ok(11), {})
        boot(30, :mold_pid => 901, :generation => 1)
        boot(31, :mold_pid => 901, :generation => 1)
        ping(30, 9)
        expect(sent('URG')).to eq [10, 11]
        ping(30, 10)
        expect(sent('URG')).to eq [10, 11, 30]
      end

      it 'do not advance on a promotion after a lost mold' do
        activate
        supervisor.reaped(900)
        expect(logged).to include 'Lost mold (pid 900); promoting a new mold in 10s'
        supervisor.tick
        expect(sent('URG')).to eq [10] # Held.
        travel(11)
        supervisor.tick
        expect(sent('URG')).to eq [10, 11]
        expect(logged).to include '(mold_lost)'
        line('M', 11, 902)
        line('m', 902, 11)
        expect(supervisor.generation).to eq 2
        supervisor.child_exited(11, ok(11), {})
        boot(40, :mold_pid => 902, :generation => 2)
        ping(40, 9)
        expect(sent('URG')).to eq [10, 11]
        ping(40, 10) # The second threshold, as the lost mold's activation used the first.
        expect(sent('URG')).to eq [10, 11, 40]
      end
    end

    describe 'the retry back-off' do
      # Promotes a fresh child process, which then fails to fork a mold.
      def fail_promotion(pid)
        boot(pid)
        ping(pid, 6)
        expect(sent('URG').last).to eq pid
        supervisor.child_exited(pid, reported(pid, Delayed::Launcher::Mold::PROMOTION_FAILED), {})
        travel(described_class::MAX_RETRY_DELAY + 1)
      end

      it 'doubles per failure in a row, up to MAX_RETRY_DELAY' do
        described_class.retry_delay_unit = 200
        3.times { |i| fail_promotion(20 + i) }
        expect(logged.scan(/promoting a new mold in (\d+)s/).flatten).to eq %w[200 400 600]
      end

      it 'keeps growing when a mold is lost soon after activation' do
        described_class.retry_delay_unit = 1
        2.times { |i| fail_promotion(20 + i) }
        activate
        supervisor.reaped(900)
        expect(logged.scan(/promoting a new mold in (\d+)s/).flatten).to eq %w[1 2 4]
      end

      it 'resets once a mold has been stable' do
        described_class.retry_delay_unit = 1
        2.times { |i| fail_promotion(20 + i) }
        activate
        travel(described_class::MOLD_STABLE_UPTIME)
        supervisor.tick
        supervisor.reaped(900)
        expect(logged.scan(/promoting a new mold in (\d+)s/).flatten).to eq %w[1 2 1]
      end
    end

    describe 'refork' do
      it 'lets the replacement take over when the old child exits by itself mid-step' do
        activate
        supervisor.tick
        launcher.workers[20] = ['delayed_job.20', {}]
        supervisor.child_started(20, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
        expect(supervisor.child_exited(11, reported(11, nil, 9), {})).to be true # Its slot is the replacement's.
        line('b', 20)
        expect(sent('TERM')).to be_empty
      end

      it 'replaces as usual a replacement that dies before booting once its old child is gone' do
        activate
        supervisor.tick
        supervisor.child_started(20, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
        supervisor.child_exited(11, reported(11, 1), {})
        expect(supervisor.child_exited(20, reported(20, 3), {})).to be_falsey
      end

      it 'keeps retrying the old child until the mold counts as broken' do
        activate
        3.times do |i|
          supervisor.tick
          expect(adds.last).to eq [:add, {}, 11]
          supervisor.child_started(20 + i, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
          expect(supervisor.child_exited(20 + i, reported(20 + i, 3), {})).to be true
        end
        expect(sent('KILL')).to eq [900]
        expect(sent('TERM')).to be_empty
        expect(supervisor).not_to be_forking_from_mold
      end

      it 'stops the unbooted replacements and keeps the old children when the mold dies mid-step' do
        activate(10, 900, :others => [11, 12])
        supervisor.tick
        supervisor.child_started(20, :mold_pid => 900, :replaces_pid => 11, :generation => 1)
        supervisor.reaped(900)
        expect(sent('TERM')).to eq [20]
        expect(supervisor.child_exited(20, ok(20), {})).to be true # Not replaced.
        expect(supervisor.child_exited(11, reported(11, 1), {})).to be_falsey # Its own slot again.
      end

      it 'reforks idle children first' do
        boot(10)
        boot(11)
        boot(12)
        ping(11, 1, 2)
        ping(12, 1, 0)
        ping(10, 6)
        line('M', 10, 900)
        line('m', 900, 10)
        supervisor.child_exited(10, ok(10), {})
        supervisor.tick
        expect(adds.map(&:last) - [10]).to eq [12]
      end

      it 'never reforks a child process that has not booted' do
        activate(10, 900, :others => [])
        supervisor.child_started(11, {}) # Generation 0, not booted.
        supervisor.tick
        expect(adds.map(&:last)).to eq [10]
      end

      {1 => 0, 3 => 1, 20 => 2}.each do |count, batch|
        it "starts #{batch} refork step(s) at once with #{count} child process(es)" do
          activate(10, 900, :others => (11...(10 + count)).to_a)
          supervisor.tick
          expect(adds.map(&:last) - [10]).to have_attributes(:size => batch)
        end
      end

      it 'completes a refork of a single child process once its refilled slot boots' do
        activate(10, 900, :others => [])
        supervisor.request_fork(1, {}, :replaces_pid => 10, :generation => 1) # As the launcher does for the refill.
        supervisor.tick
        expect(logged).not_to include 'Reforked every child process'
        line('f', 900, 20, 1)
        line('b', 20)
        supervisor.tick
        expect(logged).to include 'Reforked every child process from mold (pid 900), generation 1'
      end
    end

    describe 'the circuit breaker' do
      before { activate }

      def fail_to_boot(pid)
        supervisor.child_started(pid, :mold_pid => 900, :generation => 1)
        supervisor.child_exited(pid, reported(pid, 3), {})
      end

      it 'is reset by a child process that boots' do
        fail_to_boot(30)
        fail_to_boot(31)
        boot(32, :mold_pid => 900, :generation => 1)
        fail_to_boot(33)
        fail_to_boot(34)
        expect(sent('KILL')).to be_empty
        fail_to_boot(35)
        expect(sent('KILL')).to eq [900]
      end

      it 'counts failed forks ("e") too' do
        3.times { |i| supervisor.request_fork(i, {}, :generation => 1) }
        3.times { |i| line('e', 900, i, 11) }
        expect(sent('KILL')).to eq [900]
        expect(launcher.started.count { |entry| entry.first == :start }).to eq 3
      end

      it 'does not count a child process forked by the parent' do
        3.times do |i|
          supervisor.child_started(30 + i, :generation => 1)
          supervisor.child_exited(30 + i, reported(30 + i, 3), {})
        end
        expect(sent('KILL')).to be_empty
      end

      it 'counts only the children of the active mold' do
        supervisor.child_exited(11, reported(11, 0), {}) # Leaves generation 1 only.
        boot(20, :mold_pid => 900, :generation => 1)
        supervisor.child_started(30, :mold_pid => 900, :generation => 1) # Still booting.
        supervisor.request_promotion
        supervisor.tick
        line('M', 20, 901)
        line('m', 901, 20)
        expect(supervisor.generation).to eq 2
        fail_to_boot(30) # Mold 900's.
        2.times do |i|
          supervisor.child_started(40 + i, :mold_pid => 901, :generation => 2)
          supervisor.child_exited(40 + i, reported(40 + i, 3), {})
        end
        expect(sent('KILL')).not_to include 901
      end
    end

    describe 'without a child subreaper' do
      let(:reaps_orphans) { false }

      it 'never promotes a child orphaned by its mold, and reports it gone once it stops' do
        gone = [900]
        allow(Delayed::ProcessUtil).to receive(:alive?) { |pid| !gone.include?(pid) }
        activate(10, 900, :others => [])
        boot(20, :mold_pid => 900, :generation => 1)
        boot(25, :generation => 1) # Forked by the parent.
        supervisor.tick
        expect(logged).to include 'Mold (pid 900) exited; forking child processes from the parent'
        supervisor.request_promotion
        supervisor.tick
        expect(sent('URG')).to eq [10, 25]
        gone << 20
        supervisor.tick
        expect(launcher.exits.map { |pid, status| [pid, status.to_s] }).to eq [[20, 'pid 20 exit unknown']]
      end
    end

    describe 'pools' do
      let(:pipes) { Delayed::Launcher::Mold::Pipes.new }

      after do
        pipes.instance_variables.each do |ivar|
          io = pipes.instance_variable_get(ivar)
          io.close if io.is_a?(IO) && !io.closed?
        end
      end

      it 'sends each pool index to the mold, mapping back to its queues' do
        launcher.pools = [[['a'], 1], [%w[b c], 2]]
        launcher.pools.each_with_index do |(queues, _), index|
          supervisor.request_fork(index + 3, {:queues => queues}, :generation => 2)
          worker_index, pool_index, generation = pipes.read_fork_request
          expect([worker_index, pool_index, generation]).to eq [index + 3, index, supervisor.generation]
          expect(launcher.pools[pool_index].first).to eq queues
        end
        supervisor.request_fork(9, {:queues => %w[c b]}, :generation => 2) # Not a pool's queues.
        expect(pipes.read_fork_request).to eq [9, Delayed::Launcher::Mold::NO_POOL, supervisor.generation]
      end

      it 'sends NO_POOL without pools, and the generation of the mold it asks' do
        supervisor.request_fork(1, {}, :generation => 7) # Stamped when sent, not when requested.
        expect(pipes.read_fork_request).to eq [1, Delayed::Launcher::Mold::NO_POOL, supervisor.generation]
      end
    end
  end

  describe Delayed::Launcher::Mold::Pipes do
    let(:pipes) { described_class.new }
    # The status pipe's write end, to write partial lines.
    let(:status_write) { pipes.instance_variable_get(:@status_write) }

    after do
      pipes.instance_variables.each do |ivar|
        io = pipes.instance_variable_get(ivar)
        io.close if io.is_a?(IO) && !io.closed?
      end
    end

    def statuses(timeout = 0.2)
      lines = []
      pipes.each_status(timeout) { |*status| lines << status }
      lines
    end

    it 'buffers a status line split across reads' do
      status_write.write('p 12 3')
      expect(statuses).to eq []
      status_write.write(" 1 0\nb 1")
      expect(statuses).to eq [['p', 12, 3, 1, 0]]
      status_write.write("3\n")
      expect(statuses).to eq [['b', 13]]
    end

    it 'reads "-" as nil' do
      pipes.report('x 900 55 - 9')
      pipes.report('x 900 56 0 -')
      expect(statuses).to eq [['x', 900, 55, nil, 9], ['x', 900, 56, 0, nil]]
    end

    it 'yields nothing when no line arrives in time' do
      expect(statuses(0.01)).to eq []
    end

    it 'drops pings rather than block when the pipe is full, never splitting a line' do
      sent = 0
      sent += 1 while sent < 100_000 && pipes.report("p #{sent} #{sent * 7} 0 0", :blocking => false).is_a?(Integer)
      expect(sent).to be < 100_000 # The pipe filled up.
      received = []
      loop do
        batch = statuses(0.05)
        break if batch.empty?
        received.concat(batch)
      end
      expect(received.size).to eq sent
      expect(received).to eq(Array.new(sent) { |i| ['p', i, i * 7, 0, 0] })
    end

    it 'swallows a write once the reader is gone' do
      pipes.instance_variable_get(:@status_read).close
      expect { pipes.report('b 1') }.not_to raise_error
    end

    it 'round-trips fork records, in order, and drains them' do
      pipes.request_fork(7, Delayed::Launcher::Mold::NO_POOL, 3)
      pipes.request_fork(2**31, 0, 0)
      expect(pipes.read_fork_request).to eq [7, Delayed::Launcher::Mold::NO_POOL, 3]
      expect(pipes.read_fork_request).to eq [2**31, 0, 0]
      expect(pipes.read_fork_request).to be_nil
      pipes.request_fork(1, 1, 1)
      pipes.request_fork(2, 2, 2)
      pipes.drain_fork_requests
      expect(pipes.read_fork_request).to be_nil
    end

    it 'reads :eof from the fork pipe once the parent (its only writer) is gone' do
      pipes.request_fork(4, 0, 1)
      pipes.instance_variable_get(:@fork_write).close
      expect(pipes.read_fork_request).to eq [4, 0, 1]
      expect(pipes.read_fork_request).to eq :eof
    end
  end

  describe Delayed::ProcessUtil do
    it 'counts a process owned by another user (EPERM) as gone' do
      allow(Process).to receive(:kill).and_call_original
      allow(Process).to receive(:kill).with(0, 4242).and_raise(Errno::EPERM)
      expect(described_class.alive?(4242)).to be false
      skip 'running as root' if Process.uid.zero?
      expect(described_class.alive?(1)).to be false # init: really EPERM.
    end

    it 'counts a stopped process as alive', :fork do
      skip 'Linux only' unless RUBY_PLATFORM.include?('linux')
      pid = fork { sleep 30 }
      Process.kill('STOP', pid)
      Timeout.timeout(5) { sleep 0.01 until File.read("/proc/#{pid}/stat")[/\) (\w)/, 1] == 'T' }
      expect(described_class.alive?(pid)).to be true
    ensure
      if pid
        Process.kill('KILL', pid)
        Process.wait(pid)
      end
    end

    it 'counts a reaped pid as gone', :fork do
      pid = fork { exit!(0) }
      Process.wait(pid)
      expect(described_class.alive?(pid)).to be false
    end

    it 'reads the state after the last ")" of the command name' do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with('/proc/4242/stat').and_return('4242 (evil) Z (x) S 1 4242')
      allow(File).to receive(:read).with('/proc/4243/stat').and_return('4243 (a) b) Z 1 4243')
      expect(described_class.zombie?(4242)).to be false
      expect(described_class.zombie?(4243)).to be true
    end
  end
end
