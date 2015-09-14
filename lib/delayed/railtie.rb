require 'delayed_job'
require 'rails'

module Delayed
  class Railtie < Rails::Railtie
    initializer :after_initialize do
      ActiveSupport.on_load(:action_mailer) do
        module Mail
          class Message
            include(Delayed::DelayMailMessage)
          end
        end
        ActionMailer::Base.extend(Delayed::DelayMail)
      end

      Delayed::Worker.logger ||= begin
        if defined?(Rails)
          Rails.logger
        elsif defined?(RAILS_DEFAULT_LOGGER)
          RAILS_DEFAULT_LOGGER
        end
      end
    end

    rake_tasks do
      load 'delayed/tasks.rb'
    end
  end
end
