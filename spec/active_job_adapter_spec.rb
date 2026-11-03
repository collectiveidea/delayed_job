require 'helper'

# Active Job is new in Rails 4.2
require 'active_job' if Gem.loaded_specs.key?('activejob')

if defined?(ActiveJob::Base)
  require 'concurrent'
  # Load this gem's adapter even where Rails bundles its own at the same path,
  # as happens when delayed_job comes first on the load path
  require File.expand_path('../lib/active_job/queue_adapters/delayed_job_adapter', __dir__)

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

    it 'uses this gem’s adapter' do
      adapter = ActiveJob::QueueAdapters::DelayedJobAdapter
      expect(adapter.instance_method(:enqueue).source_location.first).to start_with(File.expand_path('../lib', __dir__))
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

    it 'enqueues through the adapter class, as Rails 4.2 does' do
      ActiveJob::QueueAdapters::DelayedJobAdapter.enqueue(TestJob.new('Rails'))
      worker.work_off
      expect(JobBuffer.values).to eq(['Rails'])
    end

    it 'schedules through the adapter class, as Rails 4.2 does' do
      ActiveJob::QueueAdapters::DelayedJobAdapter.enqueue_at(TestJob.new('Rails'), 5.seconds.from_now.to_f)
      expect(Delayed::Job.all.last.run_at).to within(1.second).of(5.seconds.from_now)
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
      skip('perform_all_later is new in Rails 7.1') unless ActiveJob.respond_to?(:perform_all_later)
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
      skip('perform_all_later is new in Rails 7.1') unless ActiveJob.respond_to?(:perform_all_later)
      ActiveJob.perform_all_later([TestJob.new('Rails').set(:wait => 5.seconds)])

      expect(Delayed::Job.all.last.run_at).to within(1.second).of(5.seconds.from_now)
    end

    it 'should run job with higher priority first' do
      skip('Active Job priorities are new in Rails 5.0') unless ActiveJob::Base.method_defined?(:priority)
      wait_until = Time.now
      TestJob.set(:wait_until => wait_until, :priority => 20).perform_later '1'
      TestJob.set(:wait_until => wait_until, :priority => 10).perform_later '2'

      worker.work_off

      expect(JobBuffer.values).to eq(%w[2 1])
    end
  end
end
