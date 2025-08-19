require 'active_support/core_ext/array/extract_options'

module Delayed
  module Backend
    class JobPreparer
      attr_reader :options, :args

      def initialize(*args)
        @options = args.extract_options!.dup
        @args = args
      end

      def prepare
        set_payload
        set_queue_name
        set_priority
        set_run_at
        handle_deprecation
        options
      end

    private

      def set_payload
        options[:payload_object] ||= args.shift
      end

      def set_queue_name
        if options[:queue].nil? && options[:payload_object].respond_to?(:queue_name)
          options[:queue] = options[:payload_object].queue_name
        else
          options[:queue] ||= Delayed::Worker.default_queue_name
        end
      end

      def set_priority
        options[:priority] ||= queue_attribute(:priority) || Delayed::Worker.default_priority
      end

      def set_run_at
        run_delay = queue_attribute(:run_delay)
        return unless run_delay
        raise ArgumentError 'Option `:run_delay` must be a Numeric' unless run_delay.is_a?(Numeric)
        options[:run_at] ||= run_delay.seconds.from_now
      end

      def handle_deprecation
        if args.size > 0
          warn '[DEPRECATION] Passing multiple arguments to `#enqueue` is deprecated. Pass a hash with :priority and :run_at.'
          options[:priority] = args.first || options[:priority]
          options[:run_at]   = args[1]
        end

        # rubocop:disable GuardClause
        unless options[:payload_object].respond_to?(:perform)
          raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
        end
        # rubocop:enabled GuardClause
      end

      # Must be called after #set_queue_name
      def queue_attribute(attribute)
        attrs = Delayed::Worker.queue_attributes[options[:queue]]
        attrs && attrs[attribute]
      end
    end
  end
end
