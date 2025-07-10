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

  describe 'job_notify' do
    before do
      @worker = Delayed::Worker.new
      @job = double('job', :id => 123, :name => 'ExampleJob', :queue => nil)
      @dj = {:dj_id => 123, :dj_name => 'ExampleJob', :dj_queue => nil}
    end

    it 'call job.queue and worker.notify' do
      expect(@job).to receive(:queue)
      expect(@worker).to receive(:notify).
        with('starting', @dj)
      @worker.job_notify(@job, 'starting')
    end

    it 'notify log subscribers' do
      expect(ActiveSupport::Notifications).to receive(:instrument).
        with('starting.delayed_job', hash_including(@dj))
      @worker.job_notify(@job, 'starting')
    end

    it 'notify with job name, queue and id' do
      expect(@job).to receive(:queue).and_return('test')
      expect(@worker).to receive(:notify).
        with('starting', @dj.merge(:dj_queue => 'test'))
      @worker.job_notify(@job, 'starting')
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

  context '#notify' do
    before(:each) do
      @worker = Delayed::Worker.new
      @worker.name = 'ExampleJob'
      time = Time.now
      allow(Time).to receive(:now).and_return(time)
      @dj = {:dj_time => time.strftime('%FT%T%z'), :dj_worker => @worker.name, :quiet => true}
      @payload = {}
    end

    it 'attach dj attributes' do
      @worker.notify 'starting', @payload
      expect(@payload).to eq(@dj)
    end

    it 'notify the subscribers' do
      expect(ActiveSupport::Notifications).to receive(:instrument).
        with('starting.delayed_job', hash_including(@dj))
      @worker.notify 'starting'
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
