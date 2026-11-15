require 'helper'

describe 'Recovering the jobs of a dead worker process' do
  let(:killed) { double('Process::Status', :signaled? => true, :termsig => 9, :success? => false) }
  let(:crashed) { double('Process::Status', :signaled? => false, :termsig => nil, :exitstatus => 3, :success? => false) }

  before { Delayed::Job.delete_all }

  describe Delayed::ProcessExitError do
    it 'describes a worker killed by a signal' do
      error = described_class.new('delayed_job.1', 123, killed)
      expect(error.message).to eq 'Child process delayed_job.1 (pid 123) was killed by signal 9'
      expect([error.worker_name, error.pid, error.status]).to eq ['delayed_job.1', 123, killed]
    end

    it 'describes a worker that exited with a failure status' do
      error = described_class.new('delayed_job.0', 456, crashed)
      expect(error.message).to eq 'Child process delayed_job.0 (pid 456) exited with status 3'
    end

    it 'has an empty backtrace, so it can be recorded as a job error' do
      expect(described_class.new('w', 1, killed).backtrace).to eq []
    end
  end

  describe 'worker names' do
    it 'builds the default name for any pid' do
      expect(Delayed::Worker.default_name('dj.0 ', 42)).to match(/\Adj\.0 host:.+ pid:42\z/)
      expect(Delayed::Worker.default_name).to end_with "pid:#{Process.pid}"
    end

    it 'builds a lock name with an optional thread index' do
      expect(Delayed::Worker.lock_name('dj.0 ', 42)).to end_with 'pid:42'
      expect(Delayed::Worker.lock_name('dj.0 ', 42, 3)).to end_with 'pid:42 thread:3'
    end

    it 'matches the names workers lock jobs under' do
      dispatcher = Delayed::Dispatcher.new(:threads => 3)
      dispatcher.name_prefix = 'dj.0 '
      expect(Delayed::Worker.lock_names('dj.0 ', Process.pid, 3)).to eq dispatcher.workers.map(&:name)

      single = Delayed::Dispatcher.new
      single.name_prefix = 'dj.0 '
      expect(Delayed::Worker.lock_names('dj.0 ', Process.pid, 1)).to eq single.workers.map(&:name)
    end
  end

  describe 'Delayed::Worker.recover_jobs_of' do
    let(:error) { Delayed::ProcessExitError.new('dj.1', 77, killed) }
    let(:now) { Delayed::Job.db_time_now }

    def locked_job(locked_by, attrs = {})
      Delayed::Job.create!({:payload_object => SimpleJob.new, :locked_by => locked_by, :locked_at => now}.merge(attrs))
    end

    it 'counts the jobs of the dead workers as failed attempts and reschedules them' do
      job = locked_job('dj.1 pid:77 thread:0')
      expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77 thread:0'], error)).to eq 1

      expect(job.attempts).to eq 1
      expect(job.locked_by).to be_nil
      expect(job.locked_at).to be_nil
      expect(job.run_at).to be > now
      expect(job.last_error).to start_with 'Child process dj.1 (pid 77) was killed by signal 9'
      expect(job.failed_at).to be_nil
      expect(Delayed::Job.all).to include(job)
    end

    it 'recovers the jobs of every given worker' do
      jobs = Array.new(3) { |i| locked_job("dj.1 pid:77 thread:#{i}") }
      expect(Delayed::Worker.recover_jobs_of(jobs.map(&:locked_by), error)).to eq 3
      expect(jobs.map(&:attempts)).to eq [1, 1, 1]
      expect(jobs.map(&:locked_by)).to eq [nil, nil, nil]
    end

    it "leaves other workers' jobs alone" do
      other = locked_job('dj.2 pid:88')
      unlocked = Delayed::Job.create!(:payload_object => SimpleJob.new)
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)

      expect([other.attempts, other.locked_by]).to eq [0, 'dj.2 pid:88']
      expect(unlocked.attempts).to eq 0
    end

    context 'when the job has used its last attempt' do
      it 'fails it permanently, deleting it by default' do
        job = locked_job('dj.1 pid:77', :attempts => Delayed::Worker.max_attempts - 1)
        Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
        expect(Delayed::Job.all).not_to include(job)
      end

      it 'keeps it as failed when failed jobs are kept' do
        Delayed::Worker.destroy_failed_jobs = false
        job = locked_job('dj.1 pid:77', :attempts => Delayed::Worker.max_attempts - 1)
        Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
        expect(job.failed_at).not_to be_nil
        expect(job.last_error).to include 'was killed by signal 9'
        expect(job.locked_by).to be_nil
      ensure
        Delayed::Worker.destroy_failed_jobs = true
      end
    end

    it 'runs the :error callbacks with a worker named after the dead worker' do
      job = locked_job('dj.1 pid:77')
      seen = []
      Delayed::Worker.lifecycle.before(:error) { |worker, failed_job| seen << [worker.name, failed_job.id] }
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
      expect(seen).to eq [['dj.1 pid:77', job.id]]
    ensure
      Delayed::Worker.setup_lifecycle
    end

    it 'runs the job error hook, like a failed run' do
      payload = ErrorJob.new
      allow(payload).to receive(:error)
      job = locked_job('dj.1 pid:77', :payload_object => payload)
      allow(job).to receive(:payload_object).and_return(payload)
      allow(Delayed::Job).to receive(:locked_jobs).and_return([job])
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
      expect(job.attempts).to eq 1
    end

    context 'with a job whose payload cannot be loaded (e.g. its class was removed)' do
      def unloadable_job(locked_by, attrs = {})
        locked_job(locked_by, attrs).tap do |job|
          job.handler = "--- !ruby/object:NoSuchJobClass\nx: 1\n"
          job.send(:reset) # Forget the payload loaded when it was created.
        end
      end

      it 'reschedules it with the default back-off, and still recovers the other names' do
        bad = unloadable_job('dj.1 pid:77 thread:0')
        good = locked_job('dj.1 pid:77 thread:1')
        names = ['dj.1 pid:77 thread:0', 'dj.1 pid:77 thread:1']
        expect(Delayed::Worker.recover_jobs_of(names, error)).to eq 2
        expect([bad.attempts, bad.locked_by, bad.failed_at]).to eq [1, nil, nil]
        expect(bad.run_at).to be_within(2).of(now + 6)
        expect([good.attempts, good.locked_by]).to eq [1, nil]
      end

      it 'fails it permanently after the default max_attempts' do
        Delayed::Worker.destroy_failed_jobs = false
        bad = unloadable_job('dj.1 pid:77', :attempts => Delayed::Worker.max_attempts - 1)
        Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
        expect(bad.failed_at).not_to be_nil
        expect(bad.locked_by).to be_nil
      ensure
        Delayed::Worker.destroy_failed_jobs = true
      end
    end

    it 'reports a job it cannot recover, clears its lock, and carries on with the others' do
      reported = []
      Delayed::Worker.on_thread_error = ->(e, info) { reported << [e.message, info[:context]] }
      broken = locked_job('dj.1 pid:77 thread:0')
      good = locked_job('dj.1 pid:77 thread:1')
      allow(broken).to receive(:save!).and_raise(IOError, 'connection lost')
      names = ['dj.1 pid:77 thread:0', 'dj.1 pid:77 thread:1']
      allow(Delayed::Job).to receive(:locked_jobs).with(names).and_return([broken, good])
      expect(Delayed::Worker.recover_jobs_of(names, error)).to eq 1
      expect(reported).to eq [['connection lost', 'Recovering jobs']]
      expect(broken.locked_by).to be_nil
      expect([good.attempts, good.locked_by]).to eq [1, nil]
    end

    it 'only clears the lock of a job that had already failed permanently (it was not running)' do
      Delayed::Worker.destroy_failed_jobs = false
      failed_at = now - 60
      job = locked_job('dj.1 pid:77', :attempts => 25, :failed_at => failed_at, :last_error => 'the original error')
      events = []
      subscribe(/delayed_job/) { |name, *| events << name }
      expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)).to eq 0
      expect([job.attempts, job.failed_at, job.last_error, job.locked_by]).to eq [25, failed_at, 'the original error', nil]
      expect(events.grep(/job_attempt_failed|job_failed|jobs_released/)).to be_empty
    ensure
      Delayed::Worker.destroy_failed_jobs = true
    end

    it 'lists and clears the locks of all the names at once (a process may have hundreds)' do
      names = Delayed::Worker.lock_names('dj.1 ', 77, 16, 20)
      expect(names.size).to eq 336
      job = locked_job(names.last)
      expect(Delayed::Job).to receive(:locked_jobs).with(names).once.and_call_original
      expect(Delayed::Job).to receive(:clear_locks!).with(names).once.and_call_original
      expect(Delayed::Worker.recover_jobs_of(names, error)).to eq 1
      expect([job.attempts, job.locked_by]).to eq [1, nil]
    end

    it 'publishes one jobs_released event naming the workers whose jobs it recovered' do
      events = payloads_of(:jobs_released)
      locked_job('dj.1 pid:77 thread:0')
      2.times { locked_job('dj.1 pid:77 thread:1') }
      names = ['dj.1 pid:77 thread:0', 'dj.1 pid:77 thread:1', 'dj.1 pid:77 thread:2']
      Delayed::Worker.recover_jobs_of(names, error)
      expect(events.size).to eq 1
      expect(events.first).to include(:workers => ['dj.1 pid:77 thread:0', 'dj.1 pid:77 thread:1'], :count => 3, :reason => 'process exit')
    end

    it 'runs the :error callbacks with a worker named after the thread that held each job' do
      seen = []
      Delayed::Worker.lifecycle.before(:error) { |worker, failed_job| seen << [worker.name, failed_job.locked_by] }
      locked_job('dj.1 pid:77 thread:0')
      locked_job('dj.1 pid:77 thread:1')
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77 thread:0', 'dj.1 pid:77 thread:1'], error)
      expect(seen).to match_array [['dj.1 pid:77 thread:0'] * 2, ['dj.1 pid:77 thread:1'] * 2]
    ensure
      Delayed::Worker.setup_lifecycle
    end

    context 'when the backend cannot list locked jobs' do
      before { allow(Delayed::Job).to receive(:locked_jobs).and_return(nil) }

      it 'only clears the locks' do
        job = locked_job('dj.1 pid:77')
        expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)).to eq 0
        expect([job.locked_by, job.attempts]).to eq [nil, 0]
      end
    end
  end

  describe Delayed::Launcher::Forking do
    subject(:launcher) { described_class.new(:processes => 2, :threads => 2) }
    let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

    before do
      allow(launcher).to receive(:logger).and_return(logger)
      allow(Delayed::Worker.backend).to receive(:before_fork)
    end

    describe '#recover_jobs_of_worker' do
      let(:options) { {:threads => 2} }

      it 'recovers the jobs of every thread of a worker that died' do
        names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 2)
        expect(Delayed::Worker).to receive(:recover_jobs_of) do |lock_names, error|
          expect(lock_names).to eq names
          expect(error).to be_a Delayed::ProcessExitError
          expect(error.message).to eq 'Child process delayed_job.1 (pid 99) was killed by signal 9'
          2
        end
        expect(logger).to receive(:warn).with('Recovered 2 job(s) left locked by child process delayed_job.1 (pid 99)')
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed)
      end

      it "recovers the jobs in every thread's slots with prefetch" do
        names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 2, 1)
        host = Socket.gethostname
        expect(names).to eq(%w[0:0 0:1 1:0 1:1].map do |pair|
          thread, slot = pair.split(':')
          "delayed_job.1 host:#{host} pid:99 thread:#{thread} slot:#{slot}"
        end)
        expect(Delayed::Worker).to receive(:recover_jobs_of).with(names, anything).and_return(0)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options.merge(:prefetch => 1), crashed)
      end

      it 'uses Worker.prefetch when the options have none' do
        Delayed::Worker.prefetch = 2
        names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 1, 2)
        expect(names.size).to eq 3
        expect(Delayed::Worker).to receive(:recover_jobs_of).with(names, anything).and_return(0)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, {}, crashed)
      end

      it 'uses the single-thread name for single-threaded workers' do
        expect(Delayed::Worker).to receive(:recover_jobs_of).with([Delayed::Worker.lock_name('delayed_job.1 ', 99)], anything).and_return(0)
        expect(logger).not_to receive(:warn)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, {}, crashed)
      end

      describe 'a worker that exited cleanly' do
        let(:clean) { double('Process::Status', :success? => true) }

        it 'does not count its jobs as failed attempts' do
          expect(Delayed::Worker).not_to receive(:recover_jobs_of)
          launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, clean)
        end

        it 'releases locks it left, attempts unchanged' do
          names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 2)
          left = Delayed::Job.enqueue(SimpleJob.new)
          left.locked_by = names.last
          left.locked_at = Delayed::Job.db_time_now
          left.save!
          other = Delayed::Job.enqueue(SimpleJob.new)
          other.locked_by = 'delayed_job.2 host:x pid:100 thread:0'
          other.locked_at = Delayed::Job.db_time_now
          other.save!
          launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, clean)
          expect([left.reload.locked_by, left.locked_at, left.attempts]).to eq [nil, nil, 0]
          expect(other.reload.locked_by).to eq 'delayed_job.2 host:x pid:100 thread:0' # Another worker's.
        end

        it 'releases the locks of every one of its threads' do
          names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 2)
          expect(Delayed::Job).to receive(:clear_locks!).with(names)
          launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, clean)
        end
      end

      it 'logs and carries on when the database cannot be reached' do
        allow(Delayed::Worker).to receive(:recover_jobs_of).and_raise(IOError, 'connection refused')
        expect(logger).to receive(:error).with(/Could not recover the jobs of child process delayed_job.1 \(pid 99\): IOError: connection refused/)
        expect { launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed) }.not_to raise_error
      end

      it 'disconnects from the database afterwards, so the next fork does not inherit the connection' do
        allow(Delayed::Worker).to receive(:recover_jobs_of).and_return(0)
        expect(Delayed::Worker.backend).to receive(:before_fork)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed)
      end
    end

    describe '#run_loop' do
      let(:options) { {:threads => 2, :queues => ['mail']} }

      before do
        launcher.send(:workers)[99] = ['delayed_job.1', options]
        launcher.instance_variable_set(:@stopped, false)
      end

      # Process.wait2 reaps worker 99 with the given status, then finds no
      # more children.
      def reap(status)
        calls = 0
        allow(Process).to receive(:wait2) do
          raise Errno::ECHILD unless (calls += 1) == 1
          [99, status]
        end
      end

      it 'recovers the jobs of a crashed worker, then replaces it' do
        reap(crashed)
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, options, crashed, :promoted => false).ordered
        expect(launcher).to receive(:add_worker).with(options, :replaces_pid => 99, :delay => 0).ordered
        launcher.send(:run_loop)
      end

      it 'recovers the jobs of a SIGKILLed worker, then replaces it' do
        reap(killed)
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, options, killed, :promoted => false).ordered
        expect(launcher).to receive(:add_worker).with(options, :replaces_pid => 99, :delay => 0).ordered
        expect(launcher).not_to receive(:shutdown)
        launcher.send(:run_loop)
        expect(launcher.instance_variable_get(:@killed)).to be_falsey
      end

      it 'says that a SIGKILLed worker is replaced' do
        reap(killed)
        logger = instance_double(Logger, :info => nil, :warn => nil, :error => nil)
        allow(launcher).to receive(:logger).and_return(logger)
        allow(launcher).to receive(:recover_jobs_of_worker)
        allow(launcher).to receive(:add_worker)
        launcher.send(:run_loop)
        expect(logger).to have_received(:warn).with('Child process delayed_job.1 (pid 99) was SIGKILLed (e.g. by the OOM killer); replacing it')
      end

      it 'never shuts down the other worker processes, however often one is SIGKILLed' do
        calls = 0
        allow(Process).to receive(:wait2) do
          raise Errno::ECHILD if (calls += 1) > 3
          launcher.send(:workers)[99] = ['delayed_job.1', options]
          [99, killed]
        end
        allow(launcher).to receive(:recover_jobs_of_worker)
        expect(launcher).to receive(:add_worker).with(options, :replaces_pid => 99, :delay => 0).exactly(3).times
        expect(launcher).not_to receive(:shutdown)
        expect(launcher).not_to receive(:schedule_kill)
        launcher.send(:run_loop)
        expect(launcher.instance_variable_get(:@stopped)).to be false
      end

      it 'does not say a worker process it killed itself was SIGKILLed by someone else' do
        reap(killed)
        launcher.instance_variable_set(:@stopped, true)
        launcher.instance_variable_set(:@killed, true)
        logger = instance_double(Logger, :info => nil, :warn => nil, :error => nil)
        allow(launcher).to receive(:logger).and_return(logger)
        allow(launcher).to receive(:recover_jobs_of_worker)
        launcher.send(:run_loop)
        expect(logger).not_to have_received(:warn).with(/was SIGKILLed/)
      end

      it 'does not replace a SIGKILLed worker while stopping' do
        reap(killed)
        launcher.instance_variable_set(:@stopped, true)
        allow(launcher).to receive(:recover_jobs_of_worker)
        expect(launcher).not_to receive(:add_worker)
        expect(launcher).not_to receive(:shutdown)
        launcher.send(:run_loop)
      end
    end

    describe '#kill' do
      it 'recovers the jobs of the workers it kills' do
        launcher.send(:workers)[99] = ['delayed_job.1', {:threads => 2}]
        allow(Process).to receive(:kill)
        allow(Process).to receive(:waitpid2).with(99).and_return([99, killed])
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, {:threads => 2}, killed)
        expect { launcher.kill(1, 'test') }.to raise_error(SystemExit)
      end

      it 'recovers workers the run loop reaped meanwhile, which then skips them' do
        launcher.send(:workers)[99] = ['delayed_job.1', {}]
        allow(Process).to receive(:kill)
        allow(Process).to receive(:waitpid2).with(99).and_raise(Errno::ECHILD)
        recovered = []
        allow(launcher).to receive(:recover_jobs_of_worker) { |name, pid, _, status| recovered << [name, pid, status.termsig] }
        expect { launcher.kill(1) }.to raise_error(SystemExit)
        expect(recovered).to eq [['delayed_job.1', 99, 9]]
        expect(launcher.send(:handle_exit, 99, killed)).to be false # The run loop's reap.
        expect(recovered.size).to eq 1
      end

      it 'waits for an exit the run loop is handling before killing' do
        launcher.send(:workers)[98] = ['delayed_job.0', {}]
        allow(Process).to receive(:kill)
        allow(Process).to receive(:waitpid2).and_raise(Errno::ECHILD)
        allow(launcher).to receive(:replace_worker)
        order = Queue.new
        allow(launcher).to receive(:recover_jobs_of_worker) do |_, pid, *|
          sleep 0.2 if pid == 98
          order << pid
        end
        handling = Thread.new { launcher.send(:handle_exit, 98, killed) }
        sleep 0.01 until launcher.instance_variable_get(:@exit_lock).mon_locked?
        launcher.send(:workers)[99] = ['delayed_job.1', {}]
        expect { launcher.kill(1) }.to raise_error(SystemExit)
        handling.join
        expect(Array.new(order.size) { order.pop }).to eq [98, 99]
      end
    end
  end
end
