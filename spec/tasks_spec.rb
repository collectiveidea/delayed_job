require 'helper'
require 'rake'

describe 'jobs rake tasks' do
  before(:all) do
    @original_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../lib/delayed/tasks.rb', __dir__)
  end

  after(:all) do
    Rake.application = @original_rake
  end

  def run_task(name, *args)
    Rake::Task.tasks.each(&:reenable)
    Rake::Task[name].invoke(*args)
  end

  # Ignore any of these the surrounding shell happens to set
  TASK_ENV = %w[MIN_PRIORITY MAX_PRIORITY QUEUES QUEUE QUIET SLEEP_DELAY READ_AHEAD].freeze

  def stub_env(vars)
    stub_const('ENV', ENV.to_h.except(*TASK_ENV).merge(vars))
  end

  describe 'jobs:clear' do
    it 'deletes all jobs' do
      expect(Delayed::Job).to receive(:delete_all)
      run_task('jobs:clear')
    end
  end

  describe 'jobs:work' do
    let(:worker) { double('worker', :start => nil) }

    it 'starts a worker with the default options' do
      stub_env({})
      expect(Delayed::Worker).to receive(:new).
        with({:min_priority => nil, :max_priority => nil, :queues => [], :quiet => nil}).
        and_return(worker)
      run_task('jobs:work')
      expect(worker).to have_received(:start)
    end

    it 'reads worker options from the environment' do
      stub_env('MIN_PRIORITY' => '1', 'MAX_PRIORITY' => '9', 'QUEUES' => 'mailers,tasks',
               'QUIET' => 'true', 'SLEEP_DELAY' => '3', 'READ_AHEAD' => '2')
      expect(Delayed::Worker).to receive(:new).
        with({:min_priority => '1', :max_priority => '9', :queues => %w[mailers tasks],
              :quiet => 'true', :sleep_delay => 3, :read_ahead => 2}).
        and_return(worker)
      run_task('jobs:work')
    end

    it 'falls back to QUEUE for a single queue' do
      stub_env('QUEUE' => 'tracking')
      expect(Delayed::Worker).to receive(:new).with(hash_including(:queues => ['tracking'])).and_return(worker)
      run_task('jobs:work')
    end
  end

  describe 'jobs:workoff' do
    it 'starts a worker that exits when the jobs are done' do
      stub_env({})
      worker = double('worker', :start => nil)
      expect(Delayed::Worker).to receive(:new).with(hash_including(:exit_on_complete => true)).and_return(worker)
      run_task('jobs:workoff')
      expect(worker).to have_received(:start)
    end
  end

  describe 'jobs:check' do
    let(:jobs) { double('jobs', :count => 0) }

    before do
      allow(Delayed::Job).to receive(:where).with('attempts = 0 AND run_at < ?', anything).and_return(jobs)
    end

    it 'passes when no jobs are overdue' do
      expect { run_task('jobs:check') }.not_to raise_error
    end

    it 'only counts jobs whose run_at is older than max_age' do
      run_task('jobs:check', '60')
      expect(Delayed::Job).to have_received(:where).with('attempts = 0 AND run_at < ?', be_within(1).of(60.seconds.ago))
    end

    it 'raises when jobs are overdue' do
      allow(jobs).to receive(:count).and_return(2)
      expect { run_task('jobs:check') }.to raise_error(RuntimeError, '2 jobs older than 300 seconds have not been processed yet')
    end

    %w[true 1].each do |value|
      it "ignores locked jobs when not_locked is #{value}" do
        expect(jobs).to receive(:where).with('locked_at IS NULL').and_return(jobs)
        run_task('jobs:check', '300', value)
      end
    end

    it 'counts locked jobs when not_locked is false' do
      expect(jobs).not_to receive(:where)
      run_task('jobs:check', '300', 'false')
    end
  end
end
