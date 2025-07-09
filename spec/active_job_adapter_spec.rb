require 'helper'

if ActiveSupport.gem_version >= Gem::Version.new('8.1.0.alpha')
  require 'active_job'
  require 'concurrent'
end

describe 'a Rails active job backend' do
  before do
    if ActiveSupport.gem_version < Gem::Version.new('8.1.0.alpha')
      skip("Bundled adapter used in #{ActiveSupport.gem_version}")
    end
  end

  if ActiveSupport.gem_version >= Gem::Version.new('8.1.0.alpha')
    module JobBuffer
      @values = Concurrent::Array.new

      class << self
        def clear
          @values.clear
        end

        def add(value)
          @values << value
        end

        def values
          @values.dup
        end
      end
    end

    class TestJob < ActiveJob::Base
      queue_as :integration_tests

      def perform(message)
        JobBuffer.add(message)
      end
    end
  end

  let(:worker) { Delayed::Worker.new(:sleep_delay => 0.5, :queues => %w[integration_tests]) }

  before do
    JobBuffer.clear
    Delayed::Job.delete_all
    ActiveJob::Base.queue_adapter = :delayed_job
    ActiveJob::Base.logger = nil
  end

  it 'should supply a wrapped class name to DelayedJob' do
    TestJob.perform_later
    job = Delayed::Job.all.last
    expect(job.name).to match(/TestJob \[[0-9a-f-]+\] from DelayedJob\(integration_tests\) with arguments: \[\]/)
  end

  it 'enqueus and executes the job' do
    TestJob.perform_later('Rails')
    worker.work_off
    expect(JobBuffer.values).to eq(['Rails'])
  end

  it 'should queue the job on the correct queue' do
    old_queue = TestJob.queue_name
    begin
      TestJob.queue_as :some_other_queue
      TestJob.perform_later 'Rails'
      expect(Delayed::Job.all.last.queue).to eq('some_other_queue')
    ensure
      TestJob.queue_name = old_queue
    end
  end

  it 'runs multiple queued jobs' do
    ActiveJob.perform_all_later(TestJob.new('Rails'), TestJob.new('World'))
    worker.work_off
    expect(JobBuffer.values).to eq(%w[Rails World])
  end

  it 'should not run job enqueued in the future' do
    TestJob.set(:wait => 5.seconds).perform_later('Rails')

    worker.work_off

    expect(JobBuffer.values.empty?).to eq true
  end

  it 'should run job enqueued in the future at the specified time' do
    TestJob.set(:wait => 5.seconds).perform_later('Rails')

    expect(Delayed::Job.all.last.run_at).to within(1.second).of(5.seconds.from_now)
  end

  it 'should run job bulk enqueued in the future at the specified time' do
    ActiveJob.perform_all_later([TestJob.new('Rails').set(:wait => 5.seconds)])

    expect(Delayed::Job.all.last.run_at).to within(1.second).of(5.seconds.from_now)
  end

  it 'should run job with higher priority first' do
    wait_until = Time.now
    TestJob.set(:wait_until => wait_until, :priority => 20).perform_later '1'
    TestJob.set(:wait_until => wait_until, :priority => 10).perform_later '2'

    worker.work_off

    expect(JobBuffer.values).to eq(%w[2 1])
  end
end
