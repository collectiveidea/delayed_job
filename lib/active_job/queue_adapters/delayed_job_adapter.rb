require 'active_support/core_ext/string/inflections'

module ActiveJob
  module QueueAdapters
    # = Delayed Job adapter for Active Job
    #
    # To use Delayed Job, set the queue_adapter config to +:delayed_job+.
    #
    #   Rails.application.config.active_job.queue_adapter = :delayed_job
    #
    # Rails bundles its own copy of this adapter at the same load path, so this
    # file can load on Rails versions older than 7.2, which lack AbstractAdapter.
    base_adapter = const_defined?(:AbstractAdapter) ? AbstractAdapter : Object # simplecov:disable branch - depends on the Rails version
    class DelayedJobAdapter < base_adapter
      # Rails 4.2 calls adapters as classes rather than instances
      class << self
        def enqueue(job)
          new.enqueue(job)
        end

        def enqueue_at(job, timestamp)
          new.enqueue_at(job, timestamp)
        end
      end

      def enqueue(job)
        delayed_job = Delayed::Job.enqueue(JobWrapper.new(job.serialize), enqueue_options(job))
        job.provider_job_id = delayed_job.id if job.respond_to?(:provider_job_id=) # simplecov:disable branch - depends on the Rails version
        delayed_job
      end

      def enqueue_at(job, timestamp)
        delayed_job = Delayed::Job.enqueue(JobWrapper.new(job.serialize), enqueue_options(job).merge(:run_at => Time.at(timestamp)))
        job.provider_job_id = delayed_job.id if job.respond_to?(:provider_job_id=) # simplecov:disable branch - depends on the Rails version
        delayed_job
      end

      class JobWrapper
        attr_accessor :job_data

        def initialize(job_data)
          @job_data = job_data
        end

        def display_name
          base_name = "#{job_data['job_class']} [#{job_data['job_id']}] from DelayedJob(#{job_data['queue_name']})"

          return base_name unless log_arguments?

          "#{base_name} with arguments: #{job_data['arguments']}"
        end

        def perform
          Base.execute(job_data)
        end

      private

        # Rails 6.0 has no log_arguments setting and always logs arguments
        def log_arguments?
          job_class = job_data['job_class'].constantize
          !job_class.respond_to?(:log_arguments?) || job_class.log_arguments?
        rescue NameError
          false
        end
      end

    private

      # Rails 4.2 jobs have no priority
      def enqueue_options(job)
        {:queue => job.queue_name, :priority => (job.priority if job.respond_to?(:priority))} # simplecov:disable branch - depends on the Rails version
      end
    end
  end
end
