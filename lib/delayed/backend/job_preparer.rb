module Delayed
  module Backend
    class JobPreparer
      attr_reader :options, :args

      def initialize(*args)
        @options = args.extract_options!
        @args = args
      end

      def prepare
        set_payload
        set_queue_name
        set_priority
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
        options[:priority] ||= Delayed::Worker.default_priority
        queue_attributes = Delayed::Worker.queue_attributes.select { |queue| queue[:name].to_s == options[:queue] }
        options[:priority] = queue_attributes.first[:priority] if queue_attributes.any?
      end

      def handle_deprecation
        if args.size > 0
          warn '[DEPRECATION] Passing multiple arguments to `#enqueue` is deprecated. Pass a hash with :priority and :run_at.'
          options[:priority] = args.first || options[:priority]
          options[:run_at]   = args[1]
        end

        return if options[:payload_object].respond_to?(:perform)
        raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
      end
    end
  end
end
