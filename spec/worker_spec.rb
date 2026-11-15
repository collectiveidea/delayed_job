require 'helper'

describe Delayed::Worker do
  describe 'backend=' do
    before do
      @clazz = Class.new
      Delayed::Worker.backend = @clazz
    end

    after do
      Delayed::Worker.backend = :test
    end

    it 'sets the Delayed::Job constant to the backend' do
      expect(Delayed::Job).to eq(@clazz)
    end

    it 'sets backend with a symbol' do
      Delayed::Worker.backend = :test
      expect(Delayed::Worker.backend).to eq(Delayed::Backend::Test::Job)
    end
  end

  describe 'job_say' do
    before do
      @worker = Delayed::Worker.new
      @job = double('job', :id => 123, :name => 'ExampleJob', :queue => nil)
    end

    it 'logs with job name and id' do
      expect(@job).to receive(:queue)
      expect(@worker).to receive(:say).
        with('Job ExampleJob (id=123) message', Delayed::Worker.default_log_level)
      @worker.job_say(@job, 'message')
    end

    it 'logs with job name, queue and id' do
      expect(@job).to receive(:queue).and_return('test')
      expect(@worker).to receive(:say).
        with('Job ExampleJob (id=123) (queue=test) message', Delayed::Worker.default_log_level)
      @worker.job_say(@job, 'message')
    end

    it 'has a configurable default log level' do
      Delayed::Worker.default_log_level = 'error'

      expect(@worker).to receive(:say).
        with('Job ExampleJob (id=123) message', 'error')
      @worker.job_say(@job, 'message')
    end
  end

  context 'worker read-ahead' do
    before do
      @read_ahead = Delayed::Worker.read_ahead
    end

    after do
      Delayed::Worker.read_ahead = @read_ahead
    end

    it 'reads five jobs' do
      expect(Delayed::Job).to receive(:find_available).with(anything, 5, anything).and_return([])
      Delayed::Job.reserve(Delayed::Worker.new)
    end

    it 'reads a configurable number of jobs' do
      Delayed::Worker.read_ahead = 15
      expect(Delayed::Job).to receive(:find_available).with(anything, Delayed::Worker.read_ahead, anything).and_return([])
      Delayed::Job.reserve(Delayed::Worker.new)
    end
  end

  describe 'name' do
    it 'appends the thread index when set' do
      worker = Delayed::Worker.new
      worker.name_prefix = 'delayed_job.0 '
      worker.thread_index = 2
      expect(worker.name).to start_with('delayed_job.0 ')
      expect(worker.name).to end_with(" pid:#{Process.pid} thread:2")
    end

    it 'does not include a thread index by default' do
      expect(Delayed::Worker.new.name).not_to include('thread:')
    end
  end

  describe '#start' do
    it 'runs the worker in a single-threaded Delayed::Dispatcher' do
      worker = Delayed::Worker.new
      worker.name_prefix = 'dj.0 '
      expect_any_instance_of(Delayed::Dispatcher).to receive(:start) do |dispatcher|
        expect(dispatcher.workers).to eq [worker]
        expect(dispatcher.name_prefix).to eq 'dj.0 '
      end
      worker.start
    end

    it 'stops the dispatcher when the worker is stopped' do
      Delayed::Worker.sleep_delay = 30
      worker = Delayed::Worker.new
      allow_any_instance_of(Delayed::Dispatcher).to receive(:trap_signals)
      thread = Thread.new { worker.start }
      sleep 0.2
      worker.stop
      expect(Timeout.timeout(2) { thread.join }).to eq thread
      Delayed::Worker.sleep_delay = Delayed::Worker::DEFAULT_SLEEP_DELAY
    end
  end

  context 'worker exit on complete' do
    before do
      Delayed::Worker.exit_on_complete = true
    end

    after do
      Delayed::Worker.exit_on_complete = false
    end

    it 'exits the loop when no jobs are available' do
      worker = Delayed::Worker.new
      Timeout.timeout(2) do
        worker.start
      end
    end
  end

  context 'worker job reservation' do
    before do
      Delayed::Worker.exit_on_complete = true
    end

    after do
      Delayed::Worker.exit_on_complete = false
    end

    it 'handles error during job reservation' do
      expect(Delayed::Job).to receive(:reserve).and_raise(Exception)
      Delayed::Worker.new.work_off
    end

    it 'gives up after 10 backend failures' do
      expect(Delayed::Job).to receive(:reserve).exactly(10).times.and_raise(Exception)
      worker = Delayed::Worker.new
      9.times { worker.work_off }
      expect { worker.work_off }.to raise_exception Delayed::FatalBackendError
    end

    it 'counts a job that fails to deserialize as failed and keeps working' do
      Delayed::Job.delete_all
      SimpleJob.runs = 0
      Delayed::Job.create(:handler => '--- !ruby/object:JobThatDoesNotExist {}', :run_at => 1.minute.ago)
      Delayed::Job.enqueue(SimpleJob.new)
      expect(Delayed::Worker.new.work_off).to eq [1, 1]
    end

    it 'reuses its dispatcher, so reservation failures accumulate across calls' do
      worker = Delayed::Worker.new
      worker.work_off
      dispatcher = worker.dispatcher
      expect(dispatcher).to be_a Delayed::Dispatcher
      worker.work_off
      expect(worker.dispatcher).to equal dispatcher
    end

    it 'allows the backend to attempt recovery from reservation errors' do
      expect(Delayed::Job).to receive(:reserve).and_raise(Exception)
      expect(Delayed::Job).to receive(:recover_from).with(instance_of(Exception))
      Delayed::Worker.new.work_off
    end
  end

  context '#say' do
    before(:each) do
      @logger = Delayed::Worker.logger
      @worker = Delayed::Worker.new
      @worker.name = 'ExampleJob'
      @worker.logger = double('job')
      time = Time.now
      allow(Time).to receive(:now).and_return(time)
      @text = 'Job executed'
      @worker_name = '[Worker(ExampleJob)]'
      @expected_time = time.strftime('%FT%T%z')
    end

    # Worker#logger= sets the class-wide logger: restore it, or later
    # examples' launchers log to STDOUT.
    after(:each) do
      Delayed::Worker.logger = @logger
    end

    shared_examples_for 'a worker which logs on the correct severity' do |severity|
      it "logs a message on the #{severity[:level].upcase} level given a string" do
        expect(@worker.logger).to receive(:send).
          with(severity[:level], "#{@expected_time}: #{@worker_name} #{@text}")
        @worker.say(@text, severity[:level])
      end

      it "logs a message on the #{severity[:level].upcase} level given a fixnum" do
        expect(@worker.logger).to receive(:send).
          with(severity[:level], "#{@expected_time}: #{@worker_name} #{@text}")
        @worker.say(@text, severity[:index])
      end
    end

    severities = [{:index => 0, :level => 'debug'},
                  {:index => 1, :level => 'info'},
                  {:index => 2, :level => 'warn'},
                  {:index => 3, :level => 'error'},
                  {:index => 4, :level => 'fatal'},
                  {:index => 5, :level => 'unknown'}]
    severities.each do |severity|
      it_behaves_like 'a worker which logs on the correct severity', severity
    end

    it 'logs a message on the default log\'s level' do
      expect(@worker.logger).to receive(:send).
        with('info', "#{@expected_time}: #{@worker_name} #{@text}")
      @worker.say(@text, Delayed::Worker.default_log_level)
    end
  end

  describe 'plugin registration' do
    it 'does not double-register plugins on worker instantiation' do
      performances = 0
      plugin = Class.new(Delayed::Plugin) do
        callbacks do |lifecycle|
          lifecycle.before(:enqueue) { performances += 1 }
        end
      end
      Delayed::Worker.plugins << plugin

      Delayed::Worker.new
      Delayed::Worker.new
      Delayed::Worker.lifecycle.run_callbacks(:enqueue, nil) {}

      expect(performances).to eq(1)
    end
  end

  describe '.new while a job runs' do
    before { SimpleJob.runs = 0 }

    # A job that calls Delayed::Worker.new while it runs.
    def enqueue_job_calling_new
      payload = SimpleJob.new
      def payload.perform
        Delayed::Worker.new
      end
      Delayed::Job.enqueue(payload)
    end

    it 'raises, failing the job, instead of resetting every worker' do
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      Delayed::Worker.lifecycle.before(:perform) { |_w, _j| nil } # Would be lost by a reset.
      lifecycle = Delayed::Worker.lifecycle
      job = enqueue_job_calling_new
      expect(worker.work_off(1)).to eq [0, 1]
      expect(job.reload.last_error).to start_with 'Delayed::Worker.new was called from a running job'
      expect(Delayed::Worker.lifecycle).to equal lifecycle
    end

    it 'raises on worker threads too' do
      job = enqueue_job_calling_new
      dispatcher = Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.05)
      silence_say(*and_workers(dispatcher))
      lifecycle = Delayed::Worker.lifecycle
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(job.reload.last_error).to start_with 'Delayed::Worker.new was called from a running job'
      expect(Delayed::Worker.lifecycle).to equal lifecycle
    end

    it 'is allowed again once the job is done, on the same thread' do
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      Delayed::Job.enqueue(SimpleJob.new)
      worker.work_off(1)
      expect(Thread.current[:delayed_job_running]).to be_falsey
      expect { Delayed::Worker.new }.not_to raise_error
    end

    it 'is allowed after a job that raised' do
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      Delayed::Job.enqueue(ErrorJob.new)
      worker.work_off(1)
      expect { Delayed::Worker.new }.not_to raise_error
    end
  end
end
