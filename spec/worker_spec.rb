require 'helper'
require 'tmpdir'

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

  context 'worker daemon' do
    after do
      Delayed::Worker.sleep_delay = Delayed::Worker::DEFAULT_SLEEP_DELAY
    end

    it 'exits the loop when interrupted' do
      Delayed::Worker.sleep_delay = 60
      worker = Delayed::Worker.new

      thread = Thread.new do
        sleep(0.5)
        worker.stop
      end
      begin
        Timeout.timeout(2) do
          worker.start
        end
      ensure
        thread.join
      end
    end

    it 'honors the sleep delay' do
      Delayed::Worker.sleep_delay = 0.5
      worker = Delayed::Worker.new
      expect(worker).to receive(:reload!).once

      thread = Thread.new do
        sleep(0.7)
        worker.stop
      end
      begin
        Timeout.timeout(2) do
          initial = process_time
          worker.start
          expect(process_time).to be_within(0.2).of(initial + 0.7)
        end
      ensure
        thread.join
      end
    end

    def process_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

  describe '.guess_backend' do
    it 'warns that it is deprecated' do
      expect { Delayed::Worker.guess_backend }.to output(/guess_backend is deprecated/).to_stderr
    end
  end

  describe 'forking' do
    let(:dir) { Dir.mktmpdir }
    let(:open_file) { File.open(File.join(dir, 'open.log'), 'w') }
    let(:closed_file) { File.open(File.join(dir, 'closed.log'), 'w') { |file| file } }
    let(:broken_file) { double('File', :closed? => false, :path => File.join(dir, 'broken.log')) }

    before do
      allow(ObjectSpace).to receive(:each_object).with(File).
        and_yield(open_file).and_yield(closed_file).and_yield(broken_file)
      allow(broken_file).to receive(:reopen).and_raise(IOError)
    end

    after do
      Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)
      open_file.close
      FileUtils.remove_entry(dir)
    end

    it 'remembers open files once and lets the backend prepare' do
      expect(Delayed::Job).to receive(:before_fork).twice.and_call_original
      Delayed::Worker.before_fork
      Delayed::Worker.before_fork
      expect(ObjectSpace).to have_received(:each_object).once
      expect(Delayed::Worker.instance_variable_get(:@files_to_reopen)).to eq([open_file, broken_file])
    end

    it 'reopens remembered files after forking' do
      Delayed::Worker.before_fork
      expect(open_file).to receive(:reopen).with(open_file.path, 'a+').and_call_original
      expect(Delayed::Job).to receive(:after_fork).and_call_original
      Delayed::Worker.after_fork
      expect(open_file.sync).to be true
    end
  end

  describe '.reload_app?' do
    let(:config) { double('config', :cache_classes => false) }

    before do
      stub_const('ActionDispatch::Reloader', Class.new)
      allow(Rails).to receive(:application).and_return(double('application', :config => config))
    end

    it 'is true when classes are not cached' do
      expect(Delayed::Worker.reload_app?).to be true
    end

    it 'is false when classes are cached' do
      allow(config).to receive(:cache_classes).and_return(true)
      expect(Delayed::Worker.reload_app?).to be false
    end
  end

  describe '#reload!' do
    it 'does nothing when the app does not need reloading' do
      allow(Delayed::Worker).to receive(:reload_app?).and_return(false)
      expect(Rails).not_to receive(:application)
      Delayed::Worker.new.send(:reload!)
    end

    it 'reloads the app' do
      reloader = double('reloader')
      allow(Delayed::Worker).to receive(:reload_app?).and_return(true)
      allow(Rails).to receive(:application).and_return(double('application', :reloader => reloader))
      expect(reloader).to receive(:reload!)
      Delayed::Worker.new.send(:reload!)
    end
  end

  describe '.delay_job?' do
    it 'calls a proc without arguments' do
      Delayed::Worker.delay_jobs = -> { false }
      expect(Delayed::Worker.delay_job?(double('job'))).to be false
    end
  end

  describe 'options' do
    it 'applies worker options to the class settings' do
      Delayed::Worker.new(:min_priority => 1, :max_priority => 9, :sleep_delay => 3, :read_ahead => 2, :queues => %w[a], :exit_on_complete => true)
      expect(Delayed::Worker.min_priority).to eq(1)
      expect(Delayed::Worker.max_priority).to eq(9)
      expect(Delayed::Worker.sleep_delay).to eq(3)
      expect(Delayed::Worker.read_ahead).to eq(2)
      expect(Delayed::Worker.queues).to eq(%w[a])
      expect(Delayed::Worker.exit_on_complete).to be true
    ensure
      Delayed::Worker.min_priority = nil
      Delayed::Worker.max_priority = nil
      Delayed::Worker.exit_on_complete = false
    end
  end

  describe 'quiet option' do
    it 'prints messages when not quiet' do
      worker = Delayed::Worker.new(:quiet => false)
      worker.name = 'loud'
      expect { worker.say('hello') }.to output("[Worker(loud)] hello\n").to_stdout
    end
  end

  describe 'without a logger' do
    around do |example|
      logger = Delayed::Worker.logger
      Delayed::Worker.logger = nil
      example.run
    ensure
      Delayed::Worker.logger = logger
    end

    it 'only prints messages' do
      worker = Delayed::Worker.new(:quiet => false)
      worker.name = 'loud'
      expect { worker.say('hello') }.to output("[Worker(loud)] hello\n").to_stdout
    end
  end

  describe 'class setting accessors' do
    settings = %i(min_priority max_priority default_priority sleep_delay delay_jobs queues read_ahead plugins
                  destroy_failed_jobs exit_on_complete default_log_level default_queue_name raise_signal_exceptions)

    it 'reads and writes class settings from an instance' do
      worker = Delayed::Worker.new
      settings.each do |setting|
        value = Delayed::Worker.public_send(setting)
        worker.public_send(:"#{setting}=", value)
        expect(worker.public_send(setting)).to eq(value)
      end
      worker.max_attempts = Delayed::Worker.max_attempts
      worker.max_run_time = Delayed::Worker.max_run_time
      expect(worker.backend).to eq(Delayed::Worker.backend)
      expect(worker.queue_attributes).to eq(Delayed::Worker.queue_attributes)
    end
  end

  describe '#start' do
    let(:worker) { Delayed::Worker.new }
    let(:traps) { {} }

    before do
      Delayed::Job.delete_all
      allow(worker).to receive(:trap) { |signal, &block| traps[signal] = block }
    end

    after do
      Delayed::Worker.exit_on_complete = false
      Delayed::Worker.raise_signal_exceptions = false
    end

    it 'sleeps and reloads while waiting for jobs' do
      worker.sleep_delay = 7
      expect(worker).to receive(:sleep).with(7) { worker.stop }
      expect(worker).to receive(:reload!)
      worker.start
      expect(worker).to be_stop
    end

    it 'reports processed jobs and keeps working until none are left' do
      Delayed::Worker.exit_on_complete = true
      'hello'.delay.length
      expect(worker).to receive(:say).with('Starting job worker')
      expect(worker).to receive(:say).with(/1 jobs processed at \d+\.\d{4} j\/s, 0 failed/)
      expect(worker).to receive(:say).with('No more jobs available. Exiting')
      allow(worker).to receive(:job_say)
      worker.start
      expect(Delayed::Job.count).to eq(0)
    end

    it 'does not sleep once stopped' do
      worker.stop
      expect(worker).not_to receive(:sleep)
      worker.start
    end

    context 'when handling signals' do
      before do
        Delayed::Worker.exit_on_complete = true
        worker.start
        allow(Thread).to receive(:new) { |&block| block.call }
      end

      %w[TERM INT].each do |signal|
        it "stops on #{signal}" do
          traps[signal].call
          expect(worker).to be_stop
        end

        it "raises on #{signal} when signal exceptions are enabled" do
          Delayed::Worker.raise_signal_exceptions = true
          expect { traps[signal].call }.to raise_error(SignalException, "SIG#{signal}")
        end
      end

      it 'raises on TERM only when signal exceptions are :term' do
        Delayed::Worker.raise_signal_exceptions = :term
        traps['INT'].call
        expect { traps['TERM'].call }.to raise_error(SignalException, 'SIGTERM')
      end
    end
  end

  describe '#work_off' do
    it 'stops between jobs once the worker is stopped' do
      Delayed::Job.delete_all
      2.times { 'hello'.delay.length }
      worker = Delayed::Worker.new
      worker.stop
      expect(worker.work_off).to eq([1, 0])
      expect(Delayed::Job.count).to eq(1)
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
end
