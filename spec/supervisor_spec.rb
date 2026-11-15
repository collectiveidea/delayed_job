require 'helper'

describe 'Worker processes whose parent goes away' do
  describe Delayed::Dispatcher do
    let(:messages) { Concurrent::Array.new }

    def dispatcher(options = {})
      described_class.new(options).tap { |d| capture_say(messages, d) }
    end

    describe '#supervisor_pid' do
      it 'is nil by default' do
        expect(dispatcher.supervisor_pid).to be_nil
      end

      it 'is set from the :supervisor_pid option' do
        expect(dispatcher(:supervisor_pid => 42).supervisor_pid).to eq 42
      end
    end

    describe '#supervisor_gone?' do
      it 'is false when not supervised' do
        d = dispatcher
        expect(d.send(:supervisor_gone?)).to be false
        expect(d).not_to be_stop
      end

      it 'is false while the parent is the supervisor' do
        d = dispatcher(:supervisor_pid => Process.ppid)
        expect(d.send(:supervisor_gone?)).to be false
        expect(d).not_to be_stop
      end

      it 'stops the dispatcher, with a warning, once the process has been re-parented' do
        d = dispatcher(:supervisor_pid => Process.ppid + 1)
        expect(d.send(:supervisor_gone?)).to be true
        expect(d).to be_stop
        expect(d).not_to be_quit
        expect(messages).to include(['warn', "Parent process #{Process.ppid + 1} is gone; stopping"])
      end
    end

    describe '#wait_for_event' do
      it 'returns false when the timeout expires without an event' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        expect(d.send(:wait_for_event, seen, 0.01)).to be false
      end

      it 'returns true at once when an event happened since the snapshot' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        d.send(:synchronize) { d.send(:signal_event) }
        expect(d.send(:wait_for_event, seen, 5)).to be true
      end

      it 'returns true at once when stopped' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        d.stop
        expect(d.send(:wait_for_event, seen, 5)).to be true
      end

      it 'returns true when woken up by an event' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.05
          d.send(:synchronize) { d.send(:signal_event) }
        end
        expect(Timeout.timeout(5) { d.send(:wait_for_event, seen, nil) }).to be true
      end
    end

    describe '#wait_before_next_poll' do
      after { Delayed::Worker.reset }

      def timed
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      def waits_of(d)
        timeouts = []
        allow(d).to receive(:wait_for_event).and_wrap_original do |m, seen, timeout|
          timeouts << timeout
          m.call(seen, timeout)
        end
        timeouts
      end

      it 'waits sleep_delay when the queue ran dry, with no parent checks when not supervised' do
        Delayed::Worker.sleep_delay = 0.2
        d = dispatcher
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        took = timed { d.send(:wait_before_next_poll, seen, true) }
        expect(took).to be >= 0.19 # Never polls early.
        expect(took).to be < 2
        expect(timeouts.first).to be_within(0.05).of(0.2) # The whole delay at once,
        # though a wait can wake early (JRuby, several times): each later wait
        # is only for what remains.
        expect(timeouts.each_cons(2)).to all(satisfy { |earlier, later| later < earlier })
        expect(timeouts.drop(1)).to all(be < 0.2)
      end

      it 'waits for an event (no timeout) while workers are busy, when not supervised' do
        d = dispatcher
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.1
          d.send(:synchronize) { d.send(:signal_event) }
        end
        Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, false) }
        expect(timeouts).to eq [nil]
      end

      it 'checks on the supervisor every SUPERVISOR_CHECK_INTERVAL while the queue is dry, still waiting sleep_delay in all' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Worker.sleep_delay = 0.3
        d = dispatcher(:supervisor_pid => Process.ppid)
        timeouts = waits_of(d)
        allow(d).to receive(:supervisor_gone?).and_call_original
        _, seen = d.send(:snapshot)
        took = timed { d.send(:wait_before_next_poll, seen, true) }
        expect(took).to be >= 0.29 # Still sleep_delay in all: checking on the parent doesn't end the wait.
        expect(took).to be < 2
        expect(timeouts.size).to be >= 3 # Several parent checks (about 6 on an idle machine).
        expect(timeouts).to all(be <= 0.05)
        expect(d).to have_received(:supervisor_gone?).at_least(4).times
      end

      it 'checks on the supervisor every SUPERVISOR_CHECK_INTERVAL while workers are busy' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        d = dispatcher(:supervisor_pid => Process.ppid)
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.3
          d.send(:synchronize) { d.send(:signal_event) }
        end
        Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, false) }
        expect(timeouts.size).to be >= 3
        expect(timeouts).to all(eq 0.05)
      end

      it 'stops waiting, and stops the dispatcher, as soon as the supervisor is gone' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.1
          d.supervisor_pid = Process.ppid + 1 # The parent goes away (not stubbing Process.ppid, which d calls meanwhile).
        end
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
        expect(d).to be_stop
      end

      it 'returns early when a worker frees up' do
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.1
          d.send(:synchronize) { d.send(:signal_event) }
        end
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
      end

      describe 'with no sleep_delay set (nil)' do
        before { Delayed::Worker.sleep_delay = nil }

        it 'waits the default sleep_delay instead of crashing' do
          d = dispatcher(:supervisor_pid => Process.ppid)
          timeouts = waits_of(d)
          _, seen = d.send(:snapshot)
          Thread.new do
            sleep 0.2
            d.stop
          end
          expect { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }.not_to raise_error
          expect(timeouts.first).to be <= described_class::SUPERVISOR_CHECK_INTERVAL
        end

        it 'sets its deadline from the default' do
          d = dispatcher
          timeouts = waits_of(d)
          _, seen = d.send(:snapshot)
          Thread.new do
            sleep 0.1
            d.stop
          end
          Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) }
          expect(timeouts.first).to be_within(0.5).of(Delayed::Worker::DEFAULT_SLEEP_DELAY)
        end

        it 'keeps an idle (supervised) dispatcher running' do
          d = dispatcher(:supervisor_pid => Process.ppid, :threads => 2)
          Delayed::Worker.sleep_delay = nil # Worker.new may have set it.
          thread = Thread.new { d.run }
          sleep 0.3
          expect(thread).to be_alive
          d.stop
          expect { Timeout.timeout(5) { thread.join } }.not_to raise_error
        end
      end

      it 'waits a fractional sleep_delay' do
        Delayed::Worker.sleep_delay = 0.25
        d = dispatcher
        _, seen = d.send(:snapshot)
        expect(timed { d.send(:wait_before_next_poll, seen, true) }).to be >= 0.24
      end

      it 'returns early when stopped' do
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new do
          sleep 0.1
          d.stop
        end
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
      end
    end

    describe 'idle polling' do
      before { Delayed::Job.delete_all }
      after { Delayed::Worker.reset }

      # Runs an idle dispatcher for `seconds` and returns how often it polled.
      def polls_in(seconds, options)
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        polls = 0
        allow(Delayed::Job).to(receive(:reserve_batch).and_wrap_original do |m, *args|
          polls += 1
          m.call(*args)
        end)
        d = dispatcher(options.merge(:threads => 2, :sleep_delay => 0.4))
        thread = Thread.new { d.run }
        sleep seconds
        d.stop
        Timeout.timeout(5) { thread.join }
        polls
      end

      it 'polls every sleep_delay when supervised, not every SUPERVISOR_CHECK_INTERVAL' do
        # At 0, 0.4 and 0.8s, plus one as it stops on a slow machine
        # (TruffleRuby): one poll per check interval would be about 20.
        expect(polls_in(1.0, :supervisor_pid => Process.ppid)).to be_between(1, 4)
      end

      it 'polls no more often when supervised than when not' do
        supervised = polls_in(1.0, :supervisor_pid => Process.ppid)
        unsupervised = polls_in(1.0, {})
        expect(supervised).to be <= unsupervised + 1
      end
    end

    describe '#run' do
      before { Delayed::Job.delete_all }

      it 'stops when its parent goes away, letting running jobs finish' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Job.enqueue(ConcurrencyJob.new(1))
        ConcurrencyJob.reset(0.3)
        parent = Process.ppid
        d = dispatcher(:supervisor_pid => parent, :sleep_delay => 30)
        thread = Thread.new { d.run }
        sleep 0.1 until ConcurrencyJob.running == 1
        # The parent goes away. (Not by stubbing Process.ppid: the
        # dispatcher thread may call it while the stub is put in place.)
        d.supervisor_pid = parent + 1
        expect(Timeout.timeout(5) { thread.join }).to eq thread

        expect(ConcurrencyJob.runs[1]).to eq 1
        expect(ConcurrencyJob.running).to eq 0
        expect(Delayed::Job.count).to eq 0
        expect(messages.map(&:last)).to include "Parent process #{parent + 1} is gone; stopping"
      end

      it 'does not start when its parent is already gone' do
        d = dispatcher(:supervisor_pid => Process.ppid + 1)
        expect(Delayed::Job).not_to receive(:reserve_batch)
        Timeout.timeout(5) { d.run }
        expect(d).to be_stop
      end
    end
  end

  describe Delayed::Launcher::Forking do
    subject(:launcher) { described_class.new(:processes => 2) }

    it 'supervises the workers it forks with its own pid' do
      expect(launcher.send(:supervisor_pid)).to eq Process.pid
    end

    it 'passes its pid to the dispatchers of the workers it forks' do
      allow(Dir).to receive(:chdir)
      allow(Delayed::Worker).to receive(:after_fork)
      allow(launcher).to receive(:setup_logger)
      expect(Delayed::Dispatcher).to receive(:new).with(hash_including(:supervisor_pid => Process.pid)).
        and_return(double(:name_prefix= => nil, :start => nil, :cleanly_stopped? => true))
      launcher.send(:run_worker, 'delayed_job.0', {})
    end

    it 'records its pid before forking, so workers see the right parent' do
      allow(launcher).to receive(:setup_logger)
      allow(launcher).to receive(:prepare_for_fork)
      allow(launcher).to receive(:setup_workers)
      allow(launcher).to receive(:run_loop)
      allow(launcher).to receive(:trap_signals)
      allow(Delayed::Worker).to receive(:before_fork)
      launcher.launch
      expect(launcher.instance_variable_get(:@supervisor_pid)).to eq Process.pid
    end
  end

  describe Delayed::Launcher::Forking, 'on a platform without fork', :fork_guard do
    before { allow_any_instance_of(described_class).to receive(:fork_available?).and_return(false) }

    it 'is detected' do
      allow_any_instance_of(described_class).to receive(:fork_available?).and_call_original
      expect(described_class.new({}).fork_available?).to eq Process.respond_to?(:fork)
    end

    it 'refuses to fork worker processes, with a clear message' do
      launcher = described_class.new(:processes => 2)
      allow(launcher).to receive(:setup_logger)
      expect(launcher).not_to receive(:setup_workers)
      expect { launcher.launch }.to raise_error(NotImplementedError, /needs fork.*--threads/)
    end

    it 'still runs a single worker process, in this process' do
      launcher = described_class.new(:threads => 4)
      allow(launcher).to receive(:setup_logger)
      allow(launcher).to receive(:trap_signals)
      expect(Delayed::Dispatcher).to receive(:new).and_return(double(:start => nil))
      expect { launcher.launch }.not_to raise_error
    end
  end

  describe Delayed::Launcher::Daemonized do
    it 'does not supervise daemonized workers, which are detached from their parent' do
      expect(described_class.new({}).send(:supervisor_pid)).to be_nil
    end
  end
end
