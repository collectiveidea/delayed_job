# frozen_string_literal: true

module Delayed
  module Launcher

    # Represents an event sink and source.
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Events`
    class Events

      def initialize
        @hooks = Hash.new { |h, k| h[k] = [] }
      end

      # Fire callbacks for the named hook
      def fire(hook, *args)
        @hooks[hook].each { |t| t.call(*args) }
      end

      # Register a callback for a given hook
      def register(hook, obj = nil, &block)
        raise 'Specify either an object or a block, not both' if obj && block
        h = obj || block
        @hooks[hook] << h
        h
      end

      def on_booted(&block)
        register(:on_booted, &block)
      end

      def on_restart(&block)
        register(:on_restart, &block)
      end

      def on_stopped(&block)
        register(:on_stopped, &block)
      end
    end
  end
end
