# Subscribes to Delayed Job's events in specs, unsubscribing after the example.
module EventHelper
  # Subscribes the block to `<name>.delayed_job` (or a Regexp of full names).
  def subscribe(name, &block)
    pattern = name.is_a?(Regexp) ? name : "#{name}.delayed_job"
    subscriptions << ActiveSupport::Notifications.subscribe(pattern, &block)
  end

  # The payloads of the `name` events published from now on (filled in as
  # they come, from any thread).
  def payloads_of(name)
    Concurrent::Array.new.tap { |payloads| subscribe(name) { |*args| payloads << args.last } }
  end

  def subscriptions
    @subscriptions ||= []
  end

  def unsubscribe_all
    subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
  end
end
