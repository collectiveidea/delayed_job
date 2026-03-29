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

    it 'allows the backend to attempt recovery from reservation errors' do
      expect(Delayed::Job).to receive(:reserve).and_raise(Exception)
      expect(Delayed::Job).to receive(:recover_from).with(instance_of(Exception))
      Delayed::Worker.new.work_off
    end
  end

  context '#say' do
    before(:each) do
      @worker = Delayed::Worker.new
      @worker.name = 'ExampleJob'
      @worker.logger = double('job')
      time = Time.now
      allow(Time).to receive(:now).and_return(time)
      @text = 'Job executed'
      @worker_name = '[Worker(ExampleJob)]'
      @expected_time = time.strftime('%FT%T%z')
    end

    after(:each) do
      @worker.logger = nil
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

  # -------------------------------------------------------------------------
  # Fix #1237 — WorkerTimeout must honour max_attempts
  # -------------------------------------------------------------------------
  describe '#run with WorkerTimeout' do
    let(:worker) { Delayed::Worker.new }

    # A job that always sleeps longer than any max_run_time we set in tests
    let(:slow_job) do
      Delayed::Job.create!(
        :payload_object => LongRunningJob.new
      )
    end

    before do
      Delayed::Worker.destroy_failed_jobs = false
    end

    after do
      Delayed::Worker.destroy_failed_jobs = true
      Delayed::Worker.max_attempts        = Delayed::Worker::DEFAULT_MAX_ATTEMPTS
      Delayed::Worker.max_run_time        = Delayed::Worker::DEFAULT_MAX_RUN_TIME
    end

    context 'when max_attempts = 1' do
      before do
        Delayed::Worker.max_attempts = 1
        Delayed::Worker.max_run_time = 1.second
      end

      it 'marks the job as permanently failed instead of re-queuing it' do
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job).to be_failed,
          'expected failed_at to be set but the job was re-queued instead'
      end

      it 'records the timeout in last_error' do
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job.last_error).to match(/expired|WorkerTimeout/i)
      end

      it 'clears locked_by and locked_at on the failed record' do
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job.locked_by).to be_nil
        expect(slow_job.locked_at).to be_nil
      end

      it 'does not push run_at into the future' do
        original_run_at = slow_job.run_at
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job.run_at).to be <= original_run_at + 2.seconds
      end

      it 'fires the :error lifecycle callback' do
        error_fired = false
        worker # instantiate before registering — setup_lifecycle runs in initialize
               # and would discard any callback registered on the previous lifecycle
        Delayed::Worker.lifecycle.after(:error) { |_w, _j| error_fired = true }
        worker.run(slow_job)
        expect(error_fired).to be true
      end

      it 'fires the :failure lifecycle callback' do
        failure_fired = false
        worker # same reason as above
        Delayed::Worker.lifecycle.after(:failure) { |_w, _j| failure_fired = true }
        worker.run(slow_job)
        expect(failure_fired).to be true
      end

      it 'returns false (work failed)' do
        result = worker.run(slow_job)
        expect(result).to be false
      end
    end

    context 'when max_attempts > 1' do
      before do
        Delayed::Worker.max_attempts = 3
        Delayed::Worker.max_run_time = 1.second
      end

      it 'reschedules the job rather than permanently failing it' do
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job).not_to be_failed
        expect(slow_job.attempts).to eq(1)
        expect(slow_job.run_at).to be > Delayed::Job.db_time_now
      end

      it 'increments the attempts counter' do
        worker.run(slow_job)
        slow_job.reload
        expect(slow_job.attempts).to eq(1)
      end

      it 'returns false (work failed)' do
        result = worker.run(slow_job)
        expect(result).to be false
      end
    end
  end
  # -------------------------------------------------------------------------
end