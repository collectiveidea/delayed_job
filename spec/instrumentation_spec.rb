require 'helper'

describe 'Instrumentation' do
  let(:events) { Concurrent::Array.new }
  let(:log) { StringIO.new }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/\.delayed_job\z/) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  before do
    Delayed::Job.delete_all
    SimpleJob.runs = 0
    BlockingJob.reset
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(log))
  end

  after do
    BlockingJob.release = true
    Delayed::Worker.reset
  end

  def named(name)
    events.select { |event| event.name == "#{name}.delayed_job" }
  end

  def payload(name)
    found = named(name)
    expect(found.size).to eq(1), "expected one #{name} event, got #{found.size}"
    found.first.payload
  end

  describe 'Delayed.instrument' do
    it 'publishes <event>.delayed_job with the payload' do
      Delayed.instrument(:custom, :a => 1)
      expect(payload(:custom)).to eq(:a => 1)
    end

    it 'returns the result of the block and times it' do
      expect(Delayed.instrument(:custom) do
        sleep 0.02
        :done
      end).to eq :done
      expect(named(:custom).first.duration).to be >= 15
    end

    it 'yields the payload, so the block can add to it' do
      Delayed.instrument(:custom, :a => 1) { |p| p[:b] = 2 }
      expect(payload(:custom)).to eq(:a => 1, :b => 2)
    end

    it "lets the block's exceptions through, and records them in the payload" do
      expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(IOError, 'boom')
      expect(payload(:custom)[:exception]).to eq %w[IOError boom]
    end

    it "lets the block's non-standard exceptions through" do
      expect { Delayed.instrument(:custom) { raise Delayed::ShutdownInterrupt } }.to raise_error(Delayed::ShutdownInterrupt)
    end

    describe 'a failing subscriber' do
      it 'is logged and ignored for events without a block' do
        subscribe(:custom) { raise 'subscriber bug' }
        expect { Delayed.instrument(:custom) }.not_to raise_error
        expect(log.string).to include 'Error in a subscriber to custom.delayed_job: RuntimeError: subscriber bug'
      end

      it 'does not prevent or repeat the block when it fails as the event finishes' do
        subscribe(:custom) { raise 'subscriber bug' }
        runs = 0
        expect(Delayed.instrument(:custom) do
          runs += 1
          :result
        end).to eq :result
        expect(runs).to eq 1
        expect(log.string).to include 'Error in a subscriber to custom.delayed_job'
      end

      it 'still runs the block once when it fails as the event starts' do
        subscriber = Object.new
        def subscriber.start(*)
          raise 'start bug'
        end

        def subscriber.finish(*); end
        subscribe(:custom) {} # Keeps other subscribers' order realistic.
        @subscriptions << ActiveSupport::Notifications.subscribe('custom.delayed_job', subscriber)
        runs = 0
        expect(Delayed.instrument(:custom) do
          runs += 1
          :result
        end).to eq :result
        expect(runs).to eq 1
        expect(log.string).to include 'start bug'
      end

      it 'does not swallow non-standard exceptions, such as signals' do
        subscribe(:custom) { raise Interrupt }
        expect { Delayed.instrument(:custom) { :result } }.to raise_error(Interrupt)
      end

      describe 'while the block raises' do
        it "does not replace the block's exception, and is logged" do
          subscribe(:custom) { raise 'subscriber bug' }
          expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(IOError, 'boom')
          expect(log.string).to include 'Error in a subscriber to custom.delayed_job: RuntimeError: subscriber bug'
        end

        it "raises the block's exception without making the subscriber's error its cause" do
          subscribe(:custom) { raise 'subscriber bug' }
          expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(IOError) do |error|
            expect(error.cause).to be_nil
          end
        end

        it "raises the block's very exception, with its backtrace" do
          subscribe(:custom) { raise 'subscriber bug' }
          raised = IOError.new('boom')
          expect { Delayed.instrument(:custom) { raise raised } }.to raise_error do |error|
            expect(error).to equal raised
            expect(error.backtrace.first).to include __FILE__
          end
        end

        it 'does not replace a Delayed::ShutdownInterrupt' do
          subscribe(:custom) { raise 'subscriber bug' }
          expect { Delayed.instrument(:custom) { raise Delayed::ShutdownInterrupt, 'quitting' } }.
            to raise_error(Delayed::ShutdownInterrupt, 'quitting')
        end

        it 'does not replace a signal' do
          subscribe(:custom) { raise 'subscriber bug' }
          expect { Delayed.instrument(:custom) { raise Interrupt } }.to raise_error(Interrupt)
        end

        it "raises the block's exception when several subscribers fail" do
          subscribe(:custom) { raise 'first bug' }
          subscribe(:custom) { raise ArgumentError, 'second bug' }
          expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(IOError, 'boom')
          expect(log.string).to include 'Error in a subscriber to custom.delayed_job'
        end

        it 'still records the exception in the payload for the other subscribers' do
          seen = []
          subscribe(:custom) { |*args| seen << args.last[:exception] }
          subscribe(:custom) { raise 'subscriber bug' }
          expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(IOError)
          expect(seen).to eq [%w[IOError boom]]
        end

        it 'lets a signal raised by a subscriber through' do
          subscribe(:custom) { raise Interrupt }
          expect { Delayed.instrument(:custom) { raise IOError, 'boom' } }.to raise_error(Interrupt)
        end

        it 'runs the block once' do
          subscribe(:custom) { raise 'subscriber bug' }
          runs = 0
          expect do
            Delayed.instrument(:custom) do
              runs += 1
              raise IOError
            end
          end.to raise_error(IOError)
          expect(runs).to eq 1
        end
      end

      it 'does not fail the job it reports on' do
        subscribe(:job_performed) { raise 'subscriber bug' }
        job = Delayed::Job.enqueue(SimpleJob.new)
        expect(Delayed::Worker.new.work_off).to eq [1, 0]
        expect(SimpleJob.runs).to eq 1
        expect(Delayed::Job.all).not_to include job
      end
    end
  end

  describe 'job events' do
    let(:worker) { Delayed::Worker.new }

    before { worker.name = 'w1' }

    it 'publishes job_performed with the job, the worker and success' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      worker.work_off
      p = payload(:job_performed)
      expect(p[:job]).to eq job
      expect(p[:worker]).to eq 'w1'
      expect(p[:success]).to be true
    end

    it 'publishes job_performed with success false, and job_attempt_failed, for a failed attempt' do
      job = Delayed::Job.enqueue(ErrorJob.new)
      worker.work_off
      expect(payload(:job_performed)[:success]).to be false
      p = payload(:job_attempt_failed)
      expect(p[:job]).to eq job
      expect(p[:worker]).to eq 'w1'
      expect(p[:error].message).to eq 'did not work'
      expect(p[:attempts]).to eq 1
      expect(named(:job_failed)).to be_empty
    end

    it 'counts attempts across retries' do
      Delayed::Job.enqueue(ErrorJob.new, :attempts => 3)
      worker.work_off
      expect(payload(:job_attempt_failed)[:attempts]).to eq 4
    end

    it 'publishes job_failed when a job fails permanently' do
      Delayed::Worker.max_attempts = 1
      job = Delayed::Job.enqueue(ErrorJob.new)
      worker.work_off
      expect(named(:job_attempt_failed).size).to eq 1
      p = payload(:job_failed)
      expect(p[:job]).to eq job
      expect(p[:worker]).to eq 'w1'
      expect(p[:error].message).to eq 'did not work'
    end

    it 'publishes job_failed for a job that cannot be deserialized' do
      job = Delayed::Job.create(:handler => '--- !ruby/object:JobThatDoesNotExist {}')
      worker.work_off
      expect(payload(:job_failed)[:job]).to eq job
      expect(payload(:job_failed)[:error]).to be_a Delayed::DeserializationError
    end

    it 'publishes job_lock_lost when another worker took the job over' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      job.locked_by = 'w1'
      job.locked_at = Delayed::Job.db_time_now
      job.save!
      def job.destroy_if_locked_by(_name)
        false
      end
      worker.run(job)
      expect(payload(:job_lock_lost)).to include(:job => job, :worker => 'w1', :outcome => 'finished')
    end
  end

  describe 'dispatcher events' do
    let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.05, :quiet => true) }

    before { silence_say(*and_workers(dispatcher)) }

    it 'publishes process_started and process_stopped around a run' do
      Delayed::Worker.queues = %w[mail]
      run_to_completion
      start = payload(:process_started)
      expect(start).to eq(:dispatcher => dispatcher.name, :pid => Process.pid, :threads => 2, :queues => %w[mail],
                          :prefetch => 0, :prefetch_dynamic => false)
      expect(payload(:process_stopped)).to eq start.merge(:error => nil)
      expect(events.first.name).to eq 'process_started.delayed_job'
      expect(events.last.name).to eq 'process_stopped.delayed_job'
    end

    it 'publishes process_stopped with the error that stopped it' do
      allow(Delayed::Job).to receive(:reserve_batch).and_raise(IOError, 'down')
      allow(Delayed::Job).to receive(:recover_from)
      thread = run_in_thread
      expect { Timeout.timeout(5) { thread.join } }.to raise_error(Delayed::FatalBackendError)
      expect(payload(:process_stopped)[:error]).to be_a Delayed::FatalBackendError
    end

    it 'publishes jobs_reserved with the requested and reserved counts' do
      Delayed::Job.enqueue(SimpleJob.new)
      run_to_completion
      reserves = named(:jobs_reserved).map(&:payload)
      expect(reserves.first).to eq(:dispatcher => dispatcher.name, :requested => 2, :depth => 0, :reserved => 1)
      expect(reserves.last[:reserved]).to eq 0
    end

    it 'publishes jobs_reserved and thread_error when reserving fails' do
      calls = 0
      allow(Delayed::Job).to receive(:reserve_batch) do
        raise IOError, 'db hiccup' if (calls += 1) == 1
        []
      end
      allow(Delayed::Job).to receive(:recover_from)
      run_to_completion
      failed = named(:jobs_reserved).first.payload
      expect(failed[:exception]).to eq ['IOError', 'db hiccup']
      expect(failed[:reserved]).to eq 0
      expect(payload(:thread_error)).to include(:context => 'Reservation', :dispatcher => dispatcher.name, :worker => nil)
      expect(payload(:thread_error)[:error]).to be_a IOError
    end

    it 'publishes thread_error when an error escapes a worker thread' do
      Delayed::Job.enqueue(SimpleJob.new)
      allow(dispatcher.workers.first).to receive(:perform_job).and_raise(NoMemoryError, 'escaped')
      allow(dispatcher.workers.last).to receive(:perform_job).and_raise(NoMemoryError, 'escaped')
      expect { run_to_completion }.to raise_error(NoMemoryError)
      p = payload(:thread_error)
      expect(p[:context]).to eq 'Worker thread'
      expect(dispatcher.workers.map(&:name)).to include p[:worker]
      expect(payload(:process_stopped)[:error]).to be_a NoMemoryError
    end

    it 'publishes thread_error when refreshing locks fails' do
      allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
      allow(Delayed::Job).to receive(:touch_locks).and_raise(IOError, 'db hiccup')
      Delayed::Worker.lock_heartbeat_interval = 0.05
      Delayed::Worker.lock_timeout = 1
      thread = run_in_thread
      sleep 0.2
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      errors = named(:thread_error).map(&:payload)
      expect(errors).not_to be_empty
      expect(errors.map { |e| e[:context] }.uniq).to eq ['Lock heartbeat']
    end

    it 'publishes jobs_interrupted and jobs_released when running jobs are interrupted' do
      job = Delayed::Job.enqueue(BlockingJob.new)
      thread = run_in_thread
      Timeout.timeout(5) { BlockingJob.started.pop }
      worker_name = job.reload.locked_by
      dispatcher.quit
      dispatcher.stop
      Timeout.timeout(10) { thread.join }

      expect(payload(:jobs_interrupted)).to eq(:dispatcher => dispatcher.name, :jobs => 1, :reason => 'Quitting')
      expect(payload(:jobs_released)).to eq(:workers => [worker_name], :count => 1, :reason => 'shutdown')
      perform = named(:job_performed).first.payload
      expect(perform[:exception].first).to eq 'Delayed::ShutdownInterrupt'
      expect(perform).not_to have_key(:success)
    end

    it 'still releases an interrupted job when a job_performed subscriber fails' do
      subscribe(:job_performed) { raise 'subscriber bug' }
      job = Delayed::Job.enqueue(BlockingJob.new)
      thread = run_in_thread
      Timeout.timeout(5) { BlockingJob.started.pop }
      dispatcher.quit
      expect(Timeout.timeout(10) { thread.join }).to eq thread # No crash.

      job.reload
      expect([job.locked_by, job.locked_at, job.attempts]).to eq [nil, nil, 0]
      expect(payload(:jobs_released)[:reason]).to eq 'shutdown'
      expect(named(:thread_error)).to be_empty
      expect(payload(:process_stopped)[:error]).to be_nil
      expect(log.string).to include 'Error in a subscriber to job_performed.delayed_job: RuntimeError: subscriber bug'
    end

    it 'publishes no thread_error for a clean run' do
      Delayed::Job.enqueue(SimpleJob.new)
      run_to_completion
      expect(named(:thread_error)).to be_empty
      expect(named(:jobs_interrupted)).to be_empty
    end
  end

  describe 'process events' do
    let(:status) { double('Process::Status', :signaled? => true, :termsig => 9, :success? => false, :to_s => 'pid 99 SIGKILL (signal 9)') }

    it "publishes jobs_released and job_attempt_failed for a dead worker's recovered jobs" do
      job = Delayed::Job.enqueue(SimpleJob.new)
      job.locked_by = 'dead'
      job.locked_at = Delayed::Job.db_time_now
      job.save!
      allow(Delayed::Job).to receive(:locked_jobs).with(%w[dead idle]).and_return([job])
      error = Delayed::ProcessExitError.new('delayed_job.0', 99, status)
      Delayed::Worker.recover_jobs_of(%w[dead idle], error)

      expect(payload(:jobs_released)).to eq(:workers => ['dead'], :count => 1, :reason => 'process exit', :error => error)
      expect(payload(:job_attempt_failed)).to include(:job => job, :worker => 'dead', :error => error, :attempts => 1)
    end

    it 'publishes nothing for backends without locked_jobs' do
      Delayed::Worker.recover_jobs_of(%w[dead], Delayed::ProcessExitError.new('delayed_job.0', 99, status))
      expect(named(:jobs_released)).to be_empty
    end

    describe Delayed::Launcher::Forking do
      subject(:launcher) { described_class.new(:processes => 2) }

      before do
        allow(launcher).to receive(:logger).and_return(Logger.new(nil))
        allow(launcher).to receive(:recover_jobs_of_worker)
        launcher.send(:workers)[99] = ['delayed_job.1', {}]
        launcher.instance_variable_set(:@stopped, false)
        calls = 0
        allow(Process).to receive(:wait2) do
          raise Errno::ECHILD unless (calls += 1) == 1
          [99, crashed]
        end
      end

      let(:crashed) { double('Process::Status', :signaled? => false, :termsig => nil, :exitstatus => 3, :success? => false) }

      it 'publishes process_exited, then process_spawned for its replacement' do
        allow(launcher).to receive(:fork_worker).and_return(123)
        launcher.send(:run_loop)
        exited = payload(:process_exited)
        expect(exited.except(:uptime)).to eq(:worker => 'delayed_job.1', :pid => 99, :status => crashed, :respawn_in => 0)
        expect(exited[:uptime]).to be_nil # Its start wasn't recorded here.
        expect(payload(:process_spawned)).to eq(:worker => 'delayed_job.0', :pid => 123, :replaces_pid => 99, :delay => 0)
        expect(events.map(&:name).grep(/\Aprocess_(spawned|exited)/)).to eq %w[process_exited.delayed_job process_spawned.delayed_job]
      end

      it 'publishes process_exited with its uptime and the delay before its replacement' do
        launcher.send(:started_at)[99] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 2
        allow(launcher).to receive(:sleep) { launcher.instance_variable_set(:@stopped, true) }
        launcher.send(:run_loop)
        exited = payload(:process_exited)
        expect(exited[:uptime]).to be_within(1).of(2)
        expect(exited[:respawn_in]).to eq 1
      end

      it 'publishes process_exited without a replacement while stopping' do
        launcher.instance_variable_set(:@stopped, true)
        launcher.send(:run_loop)
        expect(payload(:process_exited)[:respawn_in]).to be_nil
        expect(named(:process_spawned)).to be_empty
      end

      it 'publishes process_spawned for each initial child process' do
        allow(launcher).to receive(:fork_worker).and_return(201, 202)
        launcher.send(:workers).clear
        launcher.send(:setup_multiple_workers)
        expect(named(:process_spawned).map(&:payload)).to eq [
          {:worker => 'delayed_job.0', :pid => 201, :replaces_pid => nil, :delay => 0},
          {:worker => 'delayed_job.1', :pid => 202, :replaces_pid => nil, :delay => 0}
        ]
      end
    end
  end

  describe Delayed::LogSubscriber do
    subject(:subscriber) { described_class.new }

    let(:job) { Delayed::Job.enqueue(SimpleJob.new, :queue => 'mail') }

    def event(name, payload = {}, duration_ms = 12.34)
      started = Time.now
      ActiveSupport::Notifications::Event.new("#{name}.delayed_job", started, started + duration_ms / 1000.0, 'id', payload)
    end

    def logged(name, payload = {}, level = Logger::DEBUG)
      Delayed::Worker.logger.level = level
      subscriber.public_send(name, event(name, payload))
      log.string
    end

    it 'logs to Delayed::Worker.logger' do
      expect(subscriber.logger).to be Delayed::Worker.logger
    end

    it 'logs process_started' do
      expect(logged(:process_started, :dispatcher => 'dj', :pid => 1, :threads => 2, :queues => [])).to include 'INFO -- : Started dj (pid 1, 2 thread(s), queues=*)'
      expect(logged(:process_started, :dispatcher => 'dj', :pid => 1, :threads => 1, :queues => %w[a b])).to include 'queues=a,b)'
    end

    it 'logs process_stopped, with the error if any' do
      expect(logged(:process_stopped, :dispatcher => 'dj', :pid => 1, :error => nil)).to include 'Stopped dj (pid 1)'
      expect(logged(:process_stopped, :dispatcher => 'dj', :pid => 1, :error => IOError.new('down'))).to include 'Stopped dj (pid 1) with IOError: down'
    end

    it 'logs jobs_reserved at debug level, with the failure if any' do
      expect(logged(:jobs_reserved, :dispatcher => 'dj', :requested => 4, :reserved => 2)).to include 'DEBUG -- : dj reserved 2 of 4 job(s) (12.3ms)'
      expect(logged(:jobs_reserved, :dispatcher => 'dj', :requested => 4, :reserved => 0, :exception => %w[IOError down])).to include 'reserved 0 of 4 job(s) - IOError: down'
    end

    it 'does not log debug events above debug level' do
      expect(logged(:jobs_reserved, {:dispatcher => 'dj', :requested => 4, :reserved => 2}, Logger::INFO)).to eq ''
      expect(logged(:job_performed, {:job => job, :worker => 'w', :success => true}, Logger::INFO)).to eq ''
    end

    it 'logs job_performed outcomes' do
      expect(logged(:job_performed, :job => job, :worker => 'w', :success => true)).to include "Job SimpleJob (id=#{job.id}) (queue=mail) succeeded on w (12.3ms)"
      expect(logged(:job_performed, :job => job, :worker => 'w', :success => false)).to include 'failed on w'
      expect(logged(:job_performed, :job => job, :worker => 'w', :exception => %w[Delayed::ShutdownInterrupt Quitting])).to include 'was interrupted (Delayed::ShutdownInterrupt) on w'
    end

    it 'logs job_attempt_failed, job_failed and job_lock_lost' do
      expect(logged(:job_attempt_failed, :job => job, :worker => 'w', :attempts => 2, :error => RuntimeError.new('nope'))).to include "WARN -- : Job SimpleJob (id=#{job.id}) (queue=mail) failed attempt 2 on w with RuntimeError: nope"
      expect(logged(:job_failed, :job => job, :worker => 'w')).to include 'ERROR -- : Job SimpleJob'
      expect(log.string).to include 'failed permanently on w'
      expect(logged(:job_lock_lost, :job => job, :worker => 'w', :outcome => 'finished')).to include 'was finished on w after its lock was taken over; result discarded'
    end

    it 'logs a job without a queue, and a missing job' do
      plain = Delayed::Job.enqueue(SimpleJob.new)
      expect(logged(:job_failed, :job => plain, :worker => 'w')).to include "Job SimpleJob (id=#{plain.id}) failed"
      expect(logged(:job_failed, :job => nil, :worker => 'w')).to include 'Job failed permanently on w'
    end

    it 'logs thread_error, jobs_interrupted and jobs_released' do
      expect(logged(:thread_error, :context => 'Reservation', :dispatcher => 'dj', :error => IOError.new('x'))).to include 'ERROR -- : Reservation error in dj: IOError: x'
      expect(logged(:thread_error, :context => 'Worker thread', :worker => 'w', :error => IOError.new('x'))).to include 'Worker thread error in w'
      expect(logged(:jobs_interrupted, :dispatcher => 'dj', :jobs => 2, :reason => 'Quitting')).to include 'dj interrupted 2 running job(s) (Quitting)'
      expect(logged(:jobs_released, :workers => %w[a b], :count => 3, :reason => 'process exit')).to include 'Released 3 job(s) of a, b (process exit)'
    end

    it 'logs process_exited, process_spawned and job_stuck' do
      expect(logged(:process_exited, :worker => 'delayed_job.1', :pid => 9, :status => 'exit 3', :uptime => 2.04, :respawn_in => 1)).to include \
        'INFO -- : Child process delayed_job.1 (pid 9) exited after 2.0s: exit 3; replacing it in 1s'
      expect(logged(:process_exited, :worker => 'delayed_job.1', :pid => 9, :status => 'exit 0', :uptime => nil, :respawn_in => 0)).to include \
        'Child process delayed_job.1 (pid 9) exited: exit 0; replacing it'
      expect(logged(:process_exited, :worker => 'delayed_job.1', :pid => 9, :status => 'exit 0', :uptime => 5.0, :respawn_in => nil)).to include \
        '(pid 9) exited after 5.0s: exit 0; not replaced'
      expect(logged(:process_spawned, :worker => 'delayed_job.2', :pid => 10, :replaces_pid => 9)).to include 'Child process delayed_job.2 (pid 10) spawned replacing pid 9'
      expect(logged(:process_spawned, :worker => 'delayed_job.0', :pid => 8, :replaces_pid => nil)).to include 'Child process delayed_job.0 (pid 8) spawned'
      label = "Job SimpleJob (id=#{job.id}) (queue=mail)"
      expect(job).not_to receive(:name) # It belongs to another thread.
      expect(logged(:job_stuck, :job => job, :job_name => label, :worker => 'w', :max_run_time => 60)).to include \
        "ERROR -- : #{label} is stuck on w: running past its max_run_time (60s)"
    end

    it 'logs nothing without a logger' do
      allow(Delayed::Worker).to receive(:logger).and_return(nil)
      expect { subscriber.job_failed(event(:job_failed, :job => job, :worker => 'w')) }.not_to raise_error
    end

    it 'logs the events of a run once attached' do
      described_class.attach_to :delayed_job
      Delayed::Job.enqueue(SimpleJob.new)
      Delayed::Worker.new.work_off
      expect(log.string).to match(/Job SimpleJob \(id=\d+\) succeeded on .* \(\d+\.\dms\)/)
      Delayed::Job.enqueue(ErrorJob.new)
      Delayed::Worker.max_attempts = 1
      Delayed::Worker.new.work_off
      expect(log.string).to match(/Job ErrorJob \(id=\d+\) failed attempt 1 on .* with Exception: did not work/)
      expect(log.string).to match(/Job ErrorJob \(id=\d+\) failed permanently on /)
    ensure
      described_class.detach_from :delayed_job if described_class.respond_to?(:detach_from)
    end
  end
end
