require 'active_support/notifications'

module Delayed
  # Publishes `<event>.delayed_job` events (see README, "Instrumentation").
  # Subscriber exceptions are logged and swallowed so they can't fail a job
  # or crash a worker; the instrumented block's own exceptions propagate.
  module Instrumentation
    NAMESPACE = 'delayed_job'.freeze

  module_function

    def instrument(event, payload = {})
      name = "#{event}.#{NAMESPACE}"
      return notify(name, payload) unless block_given?

      started = false
      block_error = nil
      result = nil
      begin
        ActiveSupport::Notifications.instrument(name, payload) do |p|
          started = true
          begin
            result = yield(p)
          rescue Exception => error # rubocop:disable Lint/RescueException
            block_error = error
            raise
          end
        end
      rescue Exception => error # rubocop:disable Lint/RescueException
        # The block's error, or a non-StandardError (signal, ShutdownInterrupt).
        raise if error.equal?(block_error) || !error.is_a?(StandardError)
        subscriber_failed(name, error)
        # ActiveSupport raised a finishing subscriber's error in place of the
        # block's; re-raise the block's so e.g. ShutdownInterrupt still reaches
        # the worker. :cause => nil avoids a cause loop JRuby rejects.
        raise block_error, :cause => nil if block_error
        result = yield(payload) unless started # A subscriber failed before the block ran.
      end
      result
    end

    def notify(name, payload)
      ActiveSupport::Notifications.instrument(name, payload)
    rescue StandardError => error
      subscriber_failed(name, error)
    end

    def subscriber_failed(name, error)
      logger = Delayed::Worker.logger
      logger.error("Error in a subscriber to #{name}: #{error.class}: #{error.message}") if logger
      nil
    end
  end

  def self.instrument(event, payload = {}, &block)
    Instrumentation.instrument(event, payload, &block)
  end
end
