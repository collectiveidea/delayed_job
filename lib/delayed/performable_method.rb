module Delayed
  class PerformableMethod
    attr_accessor :object, :method_name, :args

    def initialize(object, method_name, args)
      raise NoMethodError, "undefined method `#{method_name}' for #{object.inspect}" unless object.respond_to?(method_name, true)

      if object.respond_to?(:persisted?) && !object.persisted?
        raise(ArgumentError, "job cannot be created for non-persisted record: #{object.inspect}")
      end

      self.object       = object
      self.args         = args
      self.method_name  = method_name.to_sym
    end

    def display_name
      if object.is_a?(Class)
        "#{object}.#{method_name}"
      else
        "#{object.class}##{method_name}"
      end
    end

    # required to support named parameters in RUBY 3.0
    # Otherwise the following error is thrown
    # ArgumentError:
    #   wrong number of arguments (given 1, expected 0; required keywords:
    if RUBY_VERSION >= '3.0'
      def perform
        return unless object

        if args_is_a_hash?
          object.send(method_name, **args.first)
        else
          object.send(method_name, *args)
        end
      end

      def args_is_a_hash?
        args.size == 1 && args.first.is_a?(Hash)
      end
    else
      def perform
        object.send(method_name, *args) if object
      end
    end

    def method(sym)
      object.method(sym)
    end
    method_def = []
    location = caller_locations(1, 1).first
    file = location.path
    line = location.lineno
    definition = RUBY_VERSION >= '3.0' ? '...' : '*args, &block'
    method_def <<
      "def method_missing(#{definition})" \
      "  object.send(#{definition})" \
      'end'
    module_eval(method_def.join(';'), file, line)
    # rubocop:enable MethodMissing

    def respond_to?(symbol, include_private = false)
      super || object.respond_to?(symbol, include_private)
    end
  end
end
