require 'delayed_job'
require 'rails'
require 'active_job/queue_adapters/delayed_job_adapter'

module Delayed
  class Railtie < Rails::Railtie
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
