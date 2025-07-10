require 'delayed_job'
require 'rails'

module Delayed
  class Railtie < Rails::Railtie
    config.delayed_job = ::ActiveSupport::OrderedOptions.new

    initializer :after_initialize do
      Delayed::Worker.logger ||= if defined?(Rails)
        Rails.logger
      elsif defined?(RAILS_DEFAULT_LOGGER)
        RAILS_DEFAULT_LOGGER
      end

      config.after_initialize do
        if json_logging?(config)
          JsonLogSubscriber.attach_to(:delayed_job)
        else
          LogSubscriber.attach_to(:delayed_job)
        end
      end
    end

    rake_tasks do
      load 'delayed/tasks.rb'
    end

    def json_logging?(config)
      config.delayed_job.logging_format == 'json' || (ENV.fetch('DELAYED_JOB_LOG_FORMAT', 'text') == 'json')
    end
  end
end
