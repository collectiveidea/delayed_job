module Delayed
  class InvalidCallback < RuntimeError; end

  class Lifecycle
    EVENTS = {
      :enqueue => [:job],
      :execute => [:worker],
      :loop => [:worker],
      :perform => [:worker, :job],
      :error => [:worker, :job],
      :failure => [:worker, :job],
      :invoke_job => [:job]
    }.freeze

    def initialize
      @callbacks = EVENTS.keys.to_h do |e|
        [e, Callback.new]
      end
    end

    def before(event, &)
      add(:before, event, &)
    end

    def after(event, &)
      add(:after, event, &)
    end

    def around(event, &)
      add(:around, event, &)
    end

    def run_callbacks(event, *args, &)
      missing_callback(event) unless @callbacks.key?(event)

      raise ArgumentError, "Callback #{event} expects #{EVENTS[event].size} parameter(s): #{EVENTS[event].join(', ')}" unless EVENTS[event].size == args.size

      @callbacks[event].execute(*args, &)
    end

  private

    def add(type, event, &)
      missing_callback(event) unless @callbacks.key?(event)
      @callbacks[event].add(type, &)
    end

    def missing_callback(event)
      raise InvalidCallback, "Unknown callback event: #{event}"
    end
  end

  class Callback
    def initialize
      @before = []
      @after = []

      # Identity proc. Avoids special cases when there is no existing around chain.
      @around = lambda { |*args, &block| block.call(*args) }
    end

    def execute(*args, &)
      @before.each { |c| c.call(*args) }
      result = @around.call(*args, &)
      @after.each { |c| c.call(*args) }
      result
    end

    def add(type, &callback)
      case type
      when :before
        @before << callback
      when :after
        @after << callback
      when :around
        chain = @around # use a local variable so that the current chain is closed over in the following lambda
        @around = lambda { |*a, &block| chain.call(*a) { |*b| callback.call(*b, &block) } }
      else
        raise InvalidCallback, "Invalid callback type: #{type}"
      end
    end
  end
end
