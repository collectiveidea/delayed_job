module Delayed
  # Shared option rules for the command line (Delayed::Command) and env
  # vars (rake jobs:work). Errors name the option as given.
  module LaunchOptions
    POSITIVE = [:integer, ->(n) { n >= 1 }, 'must be 1 or greater'].freeze
    WHOLE = [:integer, ->(_) { true }, 'must be a whole number'].freeze
    SECONDS = [:seconds, ->(s) { s >= 0 }, 'must be a number of seconds, 0 or greater'].freeze
    POSITIVE_SECONDS = [:seconds, ->(s) { s > 0 }, 'must be greater than 0'].freeze
    PREFETCH = [:integer, ->(n) { n.between?(0, Worker::MAX_PREFETCH) }, "must be a whole number from 0 to #{Worker::MAX_PREFETCH}"].freeze

    # option => [CLI name, env var, rule]; rule is [kind, valid?, message].
    OPTIONS = {
      :processes => ['--processes', 'NUM_PROCESSES', POSITIVE],
      :threads => ['--threads', 'NUM_THREADS', POSITIVE],
      :read_ahead => ['--read-ahead', 'READ_AHEAD', POSITIVE],
      :prefetch => ['--prefetch', 'PREFETCH', PREFETCH],
      :min_priority => ['--min-priority', 'MIN_PRIORITY', WHOLE],
      :max_priority => ['--max-priority', 'MAX_PRIORITY', WHOLE],
      :sleep_delay => ['--sleep-delay', 'SLEEP_DELAY', SECONDS],
      :shutdown_timeout => ['--shutdown-timeout', 'SHUTDOWN_TIMEOUT', SECONDS],
      :lock_heartbeat_interval => ['--lock-heartbeat', 'LOCK_HEARTBEAT', POSITIVE_SECONDS],
      :lock_timeout => ['--lock-timeout', 'LOCK_TIMEOUT', POSITIVE_SECONDS],
      :identifier => ['--identifier', nil, nil],
      :queues => ['--queues', 'QUEUES', nil],
      :pools => ['--pool', 'POOLS', nil]
    }.freeze

    CLI_NAMES = OPTIONS.transform_values(&:first).freeze
    ENV_NAMES = OPTIONS.transform_values { |(_, env)| env }.compact.freeze
    RULES = OPTIONS.transform_values(&:last).compact.freeze

    # Raises ArgumentError naming `name` if invalid.
    def self.parse(option, text, name)
      kind, valid, requirement = RULES.fetch(option)
      value = kind == :integer ? Integer(text.to_s.strip, 10) : Delayed.parse_seconds(text)
      return value if valid.call(value)
      raise ArgumentError
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} #{requirement}"
    end

    # One threshold of --mold / MOLD.
    def self.parse_mold(text, name)
      value = Integer(text.to_s.strip, 10)
      raise ArgumentError unless value > 0
      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be job counts greater than 0"
    end

    # Re-checks RULES (for options not set via .parse) and cross-option
    # constraints. `names` is CLI_NAMES or ENV_NAMES.
    def self.validate!(options, names)
      RULES.each do |option, (_, valid, requirement)|
        value = options[option]
        raise ArgumentError, "#{names.fetch(option)} #{requirement}" unless value.nil? || (value.is_a?(Numeric) && valid.call(value))
      end
      validate_lock_heartbeat!(options, names)
      validate_priorities!(options, names)
      validate_exclusive!(options, names)
    end

    # The lock timeout must outlast two heartbeats.
    def self.validate_lock_heartbeat!(options, names)
      interval = options[:lock_heartbeat_interval]
      return unless interval
      timeout = options[:lock_timeout] || Worker.lock_timeout || Worker::DEFAULT_LOCK_TIMEOUT
      return if timeout >= 2 * interval
      raise ArgumentError, "#{names[:lock_timeout]} must be at least twice #{names[:lock_heartbeat_interval]}"
    end
    private_class_method :validate_lock_heartbeat!

    def self.validate_priorities!(options, names)
      min = options[:min_priority]
      max = options[:max_priority]
      return unless min && max && min > max
      raise ArgumentError, "#{names[:min_priority]} must be less than or equal to #{names[:max_priority]}"
    end
    private_class_method :validate_priorities!

    # [first, second, both_given?]
    EXCLUSIVE = [
      [:processes, :identifier, ->(o) { o[:processes].to_i > 1 && o[:identifier] }],
      [:identifier, :pools, ->(o) { o[:identifier] && o[:pools] }],
      [:processes, :pools, ->(o) { o[:processes].to_i > 1 && o[:pools] }],
      [:queues, :pools, ->(o) { o[:queues] && o[:pools] }]
    ].freeze

    def self.validate_exclusive!(options, names)
      first, second, = EXCLUSIVE.detect { |_, _, given| given.call(options) }
      raise ArgumentError, "Cannot specify both #{names[first]} and #{names[second]}" if first
    end
    private_class_method :validate_exclusive!
  end
end
