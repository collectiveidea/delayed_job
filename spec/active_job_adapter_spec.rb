require 'helper'
puts ActiveSupport.gem_version
return if ActiveSupport.gem_version < Gem::Version.new('8.1.0.alpha')

require 'active_job'
require 'concurrent'

describe 'a Rails active job backend' do
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
    start_worker do
      TestJob.perform_later('Rails')
      sleep 2
      expect(JobBuffer.values).to eq(['Rails'])
    end
  end

  it 'should not run jobs queued on a non-listening queue' do
    start_worker do
      old_queue = TestJob.queue_name

      begin
        TestJob.queue_as :some_other_queue
        TestJob.perform_later 'Rails'
        sleep 2
        expect(JobBuffer.values.empty?).to eq true
      ensure
        TestJob.queue_name = old_queue
      end
    end
  end

  it 'runs multiple queued jobs' do
    start_worker do
      ActiveJob.perform_all_later(TestJob.new('Rails'), TestJob.new('World'))
      sleep 2
      expect(JobBuffer.values).to eq(%w[Rails World])
    end
  end

  it 'should not run job enqueued in the future' do
    start_worker do
      TestJob.set(:wait => 5.seconds).perform_later('Rails')
      sleep 2
      expect(JobBuffer.values.empty?).to eq true
    end
  end

  it 'should run job enqueued in the future at the specified time' do
    start_worker do
      TestJob.set(:wait => 5.seconds).perform_later('Rails')
      sleep 10
      expect(JobBuffer.values).to eq(['Rails'])
    end
  end

  it 'should run job bulk enqueued in the future at the specified time' do
    start_worker do
      ActiveJob.perform_all_later([TestJob.new('Rails').set(:wait => 5.seconds)])
      sleep 10
      expect(JobBuffer.values).to eq(['Rails'])
    end
  end

  it 'should run job with higher priority first' do
    start_worker do
      wait_until = Time.now + 3.seconds
      TestJob.set(:wait_until => wait_until, :priority => 20).perform_later '1'
      TestJob.set(:wait_until => wait_until, :priority => 10).perform_later '2'
      sleep 10

      expect(JobBuffer.values).to eq(%w[2 1])
    end
  end

  private

  def start_worker
    thread = Thread.new { worker.start }
    yield
  ensure
    worker.stop
    thread.join
  end
end
