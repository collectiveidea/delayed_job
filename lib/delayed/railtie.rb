require 'delayed_job'
require 'rails'

module Delayed
  class Railtie < Rails::Railtie
    initializer 'delayed_job.active_job' do
      ActiveSupport.on_load(:active_job) do
        # Use Rails packaged adpater if present
        unless defined?(ActiveJob::QueueAdapters::DelayedJobAdapter)
          require 'active_job/queue_adapters/delayed_job_adapter'
        end
      end
    end

    initializer :after_initialize do
      Delayed::Worker.logger ||= if defined?(Rails)
        Rails.logger
      elsif defined?(RAILS_DEFAULT_LOGGER)
        RAILS_DEFAULT_LOGGER
      end
    end

    rake_tasks do
      load 'delayed/tasks.rb'
    end
  end
end
