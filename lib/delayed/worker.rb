require 'timeout'
require 'active_support/dependencies'
require 'active_support/core_ext/kernel/reporting'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/hash_with_indifferent_access'
require 'active_support/core_ext/hash/indifferent_access'
require 'logger'

module Delayed
  # Runs jobs, each Worker on its own Dispatcher thread; #work_off runs them
  # inline on the calling thread.
  class Worker # rubocop:disable Metrics/ClassLength
    include Logging

    DEFAULT_LOG_LEVEL        = 'info'.freeze
    DEFAULT_SLEEP_DELAY      = 1
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = [].freeze
    DEFAULT_QUEUE_ATTRIBUTES = HashWithIndifferentAccess.new.freeze
    DEFAULT_READ_AHEAD       = 5
    DEFAULT_SHUTDOWN_TIMEOUT = nil
    DEFAULT_LOCK_HEARTBEAT_INTERVAL = nil
    DEFAULT_LOCK_TIMEOUT = 5.minutes
    DEFAULT_PREFETCH = 0
    MAX_PREFETCH = 20
    DEFAULT_MOLD_THRESHOLD = 1000

    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time,
                   :default_priority, :sleep_delay, :logger, :delay_jobs, :queues,
                   :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete,
                   :default_log_level

    # prefetch: jobs each thread may hold queued behind its running one
    # (default 0: reserve only for idle threads).
    # prefetch_dynamic: start the depth at 0, grow by one after each full
    # poll (up to prefetch), and reset to 0 after a partial one.
    cattr_accessor :prefetch, :prefetch_dynamic

    # Reserve jobs for several free threads in one batch query, on backends
    # that implement one (Job.reserve_batch; e.g. delayed_job_mongoid).
    # Default false: one reservation per thread.
    cattr_accessor :batch_reserve

    # Mold process (experimental; forking launcher only): once a child process
    # has performed this many jobs, it becomes a mold that every child process
    # is then reforked from, sharing its warmed memory copy-on-write. An array
    # gives successive thresholds; true means [DEFAULT_MOLD_THRESHOLD]. After
    # the last one, SIGURG to the parent promotes a new mold. nil: off.
    cattr_accessor :mold

    # Called with errors outside job execution (reservation, heartbeats,
    # thread crashes, failure hooks, job recovery); job errors go to the
    # :error lifecycle callback instead. Handler errors are logged and ignored.
    #
    #   Delayed::Worker.on_thread_error = ->(error, info) { Sentry.capture_exception(error, extra: info) }
    #
    # `info` has :context and, where known, :dispatcher, :worker and :job.
    # The handler may take 0, 1 or 2 arguments.
    cattr_accessor :on_thread_error

    # Silences the backend's query log while polling and refreshing locks, so
    # idle workers don't log a query every sleep_delay. Job queries still log.
    cattr_accessor :silence_logging

    # Seconds to wait for running jobs on shutdown before raising
    # ShutdownInterrupt in them. nil (default) waits indefinitely.
    cattr_accessor :shutdown_timeout

    # Count a shutdown-interrupted job as a failed attempt. Off by default
    # (released, attempts unchanged), but then a job that always outlasts
    # shutdown_timeout returns on every deploy.
    cattr_accessor :count_shutdown_interrupts

    # Lock heartbeats (off by default): running jobs' locks are refreshed
    # every lock_heartbeat_interval seconds, and a lock older than
    # lock_timeout is abandoned, so a dead worker's jobs are picked up after
    # lock_timeout rather than max_run_time. Needs backend support
    # (Job.lock_heartbeats?). Enable on every worker sharing the jobs, or
    # workers without it will have their long jobs taken over.
    cattr_accessor :lock_heartbeat_interval, :lock_timeout

    # Named queue into which jobs are enqueued by default
    cattr_accessor :default_queue_name

    cattr_reader :backend, :queue_attributes

    # name_prefix is ignored if name is set directly
    attr_accessor :name_prefix

    # Appended to the default name so each thread has a unique lock name.
    attr_accessor :thread_index

    attr_accessor :dispatcher

    def self.reset
      self.default_log_level = DEFAULT_LOG_LEVEL
      self.sleep_delay       = DEFAULT_SLEEP_DELAY
      self.max_attempts      = DEFAULT_MAX_ATTEMPTS
      self.max_run_time      = DEFAULT_MAX_RUN_TIME
      self.default_priority  = DEFAULT_DEFAULT_PRIORITY
      self.delay_jobs        = DEFAULT_DELAY_JOBS
      self.queues            = DEFAULT_QUEUES
      self.queue_attributes  = DEFAULT_QUEUE_ATTRIBUTES
      self.read_ahead        = DEFAULT_READ_AHEAD
      self.shutdown_timeout  = DEFAULT_SHUTDOWN_TIMEOUT
      self.lock_heartbeat_interval = DEFAULT_LOCK_HEARTBEAT_INTERVAL
      self.lock_timeout      = DEFAULT_LOCK_TIMEOUT
      self.on_thread_error   = nil
      self.silence_logging   = false
      self.count_shutdown_interrupts = false
      self.prefetch          = DEFAULT_PREFETCH
      self.prefetch_dynamic  = false
      self.batch_reserve     = false
      self.mold              = nil
      self.exit_on_complete  = nil
      self.min_priority      = nil
      self.max_priority      = nil
      self.default_queue_name = nil
      @lifecycle = nil
    end

    # Add or remove plugins in this list before the worker is instantiated
    self.plugins = [Delayed::Plugins::ClearLocks]

    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    self.destroy_failed_jobs = true

    # By default, Signals INT and TERM stop the Delayed::Dispatcher, which exits upon completion of the current jobs.
    # If you would prefer to raise a SignalException and exit immediately you can use this.
    # Be aware daemons uses TERM to stop and restart
    # false - No exceptions will be raised
    # :term - Will only raise an exception on TERM signals but INT will wait for the current job to finish
    # true - Will raise an exception on TERM and INT
    cattr_accessor :raise_signal_exceptions
    self.raise_signal_exceptions = false

    def self.backend=(backend)
      if backend.is_a? Symbol
        require "delayed/serialization/#{backend}"
        require "delayed/backend/#{backend}"
        backend = "Delayed::Backend::#{backend.to_s.classify}::Job".constantize
      end
      @@backend = backend # rubocop:disable Style/ClassVars
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end

    def self.queue_attributes=(val)
      @@queue_attributes = val.with_indifferent_access # rubocop:disable Style/ClassVars
    end

    def self.guess_backend
      warn '[DEPRECATION] guess_backend is deprecated. Please remove it from your code.'
    end

    def self.before_fork
      unless @files_to_reopen
        @files_to_reopen = []
        ObjectSpace.each_object(File) do |file|
          # Reopening would drop the pidfile's lock.
          @files_to_reopen << file unless file.closed? || Delayed::Pidfile.lock_file?(file)
        end
      end

      backend.before_fork
    end

    def self.after_fork
      # Re-open file handles
      @files_to_reopen.each do |file|
        file.reopen file.path, 'a+'
        file.sync = true
      rescue ::Exception # rubocop:disable Lint/SuppressedException, Lint/RescueException
      end
      backend.after_fork
    end

    LIFECYCLE_LOCK = Mutex.new

    # In case a worker has not been set up, job enqueueing needs a lifecycle.
    # Locked, as several threads may enqueue at once.
    def self.lifecycle
      @lifecycle || LIFECYCLE_LOCK.synchronize do
        setup_lifecycle unless @lifecycle # Plugins read @lifecycle here, unlocked.
        @lifecycle
      end
    end

    def self.setup_lifecycle
      @lifecycle = Delayed::Lifecycle.new
      plugins.each { |klass| klass.new }
    end

    def self.default_name(prefix = nil, pid = Process.pid)
      "#{prefix}host:#{Socket.gethostname} pid:#{pid}"
    rescue StandardError
      "#{prefix}pid:#{pid}"
    end

    def self.lock_name(prefix = nil, pid = Process.pid, thread_index = nil)
      "#{default_name(prefix, pid)}#{" thread:#{thread_index}" if thread_index}"
    end

    # All lock names of a worker process (slot names when prefetching).
    def self.lock_names(prefix, pid, threads, prefetch = 0)
      names = threads <= 1 ? [lock_name(prefix, pid)] : Array.new(threads) { |index| lock_name(prefix, pid, index) }
      return names unless prefetch.to_i > 0
      names.flat_map { |name| Array.new(prefetch.to_i + 1) { |slot| slot_name(name, slot) } }
    end

    # Each held job needs its own lock name: reserving for a name also
    # returns the jobs already locked under it.
    def self.slot_name(worker_name, slot)
      "#{worker_name} slot:#{slot}"
    end

    def self.validate_prefetch!(value = prefetch)
      return if value.is_a?(Integer) && value.between?(0, MAX_PREFETCH)
      raise ArgumentError, "prefetch must be a whole number from 0 to #{MAX_PREFETCH} (got #{value.inspect})"
    end

    # Call from a job (or library code) that leaves this process unsafe to
    # fork, e.g. a background thread holding a lock in native code: with
    # Worker.mold, this child process is then never promoted to mold.
    def self.no_longer_fork_safe!
      @fork_unsafe = true
    end

    def self.fork_safe?
      !@fork_unsafe
    end

    # The mold thresholds (job counts), or nil when off.
    def self.mold_thresholds(value = mold)
      return if value.nil? || value == false
      return [DEFAULT_MOLD_THRESHOLD] if value == true
      Array(value)
    end

    def self.validate_mold!(value = mold)
      thresholds = mold_thresholds(value)
      return if thresholds.nil? || (thresholds.any? && thresholds.all? { |n| n.is_a?(Integer) && n > 0 })
      raise ArgumentError, "mold must be true or job counts greater than 0 (got #{value.inspect})"
    end

    # Counts a failed attempt (raising `error`) for each job a dead process
    # held, so a job that keeps killing its worker eventually fails. Backends
    # without Job.locked_jobs only get locks cleared. Returns the count.
    def self.recover_jobs_of(worker_names, error)
      # One query: threads x slots can be hundreds of names.
      jobs = Delayed::Job.locked_jobs(worker_names)
      if jobs.nil?
        Delayed::Job.clear_locks!(worker_names)
        return 0
      end
      # Permanently failed jobs keep their lock but weren't running: only
      # clear it. Group before recovery unlocks them.
      by_worker = jobs.reject(&:failed?).group_by(&:locked_by)
      recovered = by_worker.sum do |worker_name, held|
        worker = named(worker_name)
        held.count { |job| recover_job(worker, job, error) }
      end
      Delayed::Job.clear_locks!(worker_names)
      publish_recovered(by_worker, error)
      recovered
    end

    def self.publish_recovered(by_worker, error)
      return if by_worker.empty?
      Delayed.instrument(:jobs_released, :workers => by_worker.keys, :count => by_worker.values.sum(&:size),
                                         :reason => 'process exit', :error => error)
    end
    private_class_method :publish_recovered

    # Reports errors rather than raising, so the other jobs still recover.
    def self.recover_job(worker, job, exit_error)
      worker.fail_attempt(job, exit_error)
      true
    rescue StandardError => error
      thread_error(error, :context => 'Recovering jobs', :worker => worker.name, :job => job)
      false
    end
    private_class_method :recover_job

    # Publishes thread_error and calls on_thread_error. Never raises.
    def self.thread_error(error, info = {})
      Delayed.instrument(:thread_error, info.merge(:error => error))
      handler = on_thread_error
      return unless handler
      case handler_arity(handler)
      when 0 then handler.call
      when 1 then handler.call(error)
      else handler.call(error, info)
      end
    rescue StandardError => error
      logger.error("Error in Delayed::Worker.on_thread_error: #{error.class}: #{error.message}") if logger
    end

    def self.handler_arity(handler)
      handler.respond_to?(:arity) ? handler.arity : handler.method(:call).arity
    end
    private_class_method :handler_arity

    def self.lock_heartbeats?
      !lock_heartbeat_interval.nil? && Delayed::Job.lock_heartbeats?
    end

    def self.lock_expiry
      lock_heartbeats? ? lock_timeout : max_run_time
    end

    # A live worker's locks must not expire between two heartbeats.
    def self.validate_lock_heartbeats!(interval = lock_heartbeat_interval, timeout = lock_timeout)
      return if interval.nil?
      raise ArgumentError, 'lock_heartbeat_interval must be greater than 0' unless interval > 0
      return if timeout && timeout >= 2 * interval
      raise ArgumentError, "lock_timeout (#{timeout.inspect}) must be at least twice " \
                           "lock_heartbeat_interval (#{interval})"
    end

    # Lets the launcher fail at once rather than in every forked process.
    def self.validate_settings!(options = {})
      setting = ->(name) { options.key?(name) ? options[name] : send(name) }
      validate_prefetch!(setting.call(:prefetch))
      validate_mold!(setting.call(:mold))
      validate_lock_heartbeats!(setting.call(:lock_heartbeat_interval), setting.call(:lock_timeout))
    end

    # For recording job outcomes; unlike Worker.new, resets no global state.
    def self.named(name)
      allocate.tap do |worker|
        worker.instance_variable_set(:@quiet, true)
        worker.name = name
      end
    end

    def self.delay_job?(job)
      if delay_jobs.is_a?(Proc)
        delay_jobs.arity == 1 ? delay_jobs.call(job) : delay_jobs.call
      else
        delay_jobs
      end
    end

    def initialize(options = {})
      if Thread.current[:delayed_job_running]
        raise 'Delayed::Worker.new was called from a running job: it would reset the settings and ' \
              'plugin callbacks of every worker in this process. To run jobs inline, use Delayed::Job#invoke_job.'
      end
      @quiet = options.key?(:quiet) ? options[:quiet] : true

      [:min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :exit_on_complete, :shutdown_timeout,
       :lock_heartbeat_interval, :lock_timeout, :silence_logging, :count_shutdown_interrupts,
       :prefetch, :prefetch_dynamic, :batch_reserve, :mold].each do |option|
        self.class.send("#{option}=", options[option]) if options.key?(option)
      end

      # Reset lifecycle on the offhand chance that something lazily
      # triggered its creation before all plugins had been registered.
      self.class.setup_lifecycle
    end

    # Every worker has a unique name which by default is the pid of the process. There are some
    # advantages to overriding this with something which survives worker restarts:  Workers can
    # safely resume working on tasks which are locked by themselves. The worker will assume that
    # it crashed before.
    def name
      return @name unless @name.nil?
      self.class.lock_name(@name_prefix, Process.pid, thread_index)
    end

    # Sets the name of the worker.
    # Setting the name to nil will reset the default worker name
    attr_writer :name

    def start
      Dispatcher.new(:workers => [self], :quiet => @quiet).tap { |dispatcher| dispatcher.name_prefix = name_prefix }.start
    end

    def stop
      @exit = true
      dispatcher.stop if dispatcher
    end

    def stop?
      !!@exit
    end

    # Do num jobs inline and return stats on success/failure.
    # Exit early if interrupted or no job is available.
    def work_off(num = 100)
      (dispatcher || Dispatcher.new(:workers => [self], :quiet => @quiet)).work_off(num, self)
    end

    # time_cap: seconds left on the job's lock, if less than max_run_time.
    def run(job, time_cap = nil)
      job_say job, 'RUNNING'
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      limit = max_run_time(job).to_i
      limit = limit > 0 ? [limit, time_cap].min : time_cap if time_cap
      dispatcher.job_timed(self, job, limit) if dispatcher
      # Shutdown can interrupt only #perform, never hooks or finishing, so a
      # job that ran is never released to run again.
      Timeout.timeout(limit, WorkerTimeout) { job.invoke_job }
      owned_destroy(job)
      runtime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      job_say job, format('COMPLETED after %.4f', runtime)
      true # did work
    rescue ShutdownInterrupt
      raise # the job didn't fail; Delayed::Dispatcher releases it
    rescue SignalException => error
      # From raise_signal_exceptions: on a worker thread the dispatcher
      # releases the job; inline it counts as a failed attempt.
      raise if Dispatcher.worker_thread?
      fail_attempt(job, error)
      false # work failed
    rescue DeserializationError => error
      job_say job, "FAILED permanently with #{error.class.name}: #{error.message}", 'error'

      job.error = error
      failed(job)
      false # work failed
    rescue Exception => error # rubocop:disable Lint/RescueException
      fail_attempt(job, error)
      false # work failed
    end

    def fail_attempt(job, error)
      self.class.lifecycle.run_callbacks(:error, self, job) { handle_failed_job(job, error) }
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        time ||= job.reschedule_at
        job.run_at = time
        owner = job.locked_by
        job.unlock
        owned_save(job, owner)
      else
        job_say job, "FAILED permanently because of #{job.attempts} consecutive failures", 'error'
        failed(job)
      end
    end

    def failed(job)
      Delayed.instrument(:job_failed, :job => job, :worker => name, :error => job.error)
      self.class.lifecycle.run_callbacks(:failure, self, job) do
        job.hook(:failure)
      rescue StandardError => error
        say "Error when running failure callback: #{error}", 'error'
        say error.backtrace.join("\n"), 'error'
        self.class.thread_error(error, :context => 'Failure hook', :worker => name, :job => job)
      ensure
        job.destroy_failed_jobs? ? owned_destroy(job) : owned_fail(job)
      end
    end

    def job_say(job, text, level = default_log_level)
      text = "Job #{job.name} (id=#{job.id})#{say_queue(job.queue)} #{text}"
      say text, level
    end

    def max_attempts(job)
      job.max_attempts || self.class.max_attempts
    end

    def max_run_time(job)
      job.max_run_time || self.class.max_run_time
    end

    # Runs a reserved job with :perform callbacks; returns success.
    def perform_job(job, time_cap = nil)
      running = Thread.current[:delayed_job_running]
      Thread.current[:delayed_job_running] = true # See #initialize.
      Delayed.instrument(:job_performed, :job => job, :worker => name) do |payload|
        payload[:success] = self.class.lifecycle.run_callbacks(:perform, self, job) { run(job, time_cap) }
      end
    ensure
      Thread.current[:delayed_job_running] = running
    end

  protected

    # Write only if this worker still holds the lock; if it expired and
    # another worker took the job, that worker's outcome wins. Unguarded for
    # unlocked jobs and backends without destroy/save_if_locked_by.
    def owned_destroy(job)
      owner = job.locked_by
      return job.destroy unless owner && job.respond_to?(:destroy_if_locked_by)
      lost_lock(job, 'finished') unless job.destroy_if_locked_by(owner)
    end

    def owned_save(job, owner)
      return job.save! unless owner && job.respond_to?(:save_if_locked_by)
      lost_lock(job, 'rescheduled') unless job.save_if_locked_by(owner)
    end

    def owned_fail(job)
      owner = job.locked_by
      return job.fail! unless owner && job.respond_to?(:save_if_locked_by)
      job.failed_at = job.class.db_time_now
      lost_lock(job, 'failed') unless job.save_if_locked_by(owner)
    end

    def lost_lock(job, outcome)
      Delayed.instrument(:job_lock_lost, :job => job, :worker => name, :outcome => outcome)
      job_say job, "was #{outcome} here, but its lock expired and another worker reserved it; " \
                   'leaving the job to that worker', 'warn'
    end

    def say_queue(queue)
      " (queue=#{queue})" if queue
    end

    def handle_failed_job(job, error)
      job.error = error
      Delayed.instrument(:job_attempt_failed, :job => job, :worker => name, :error => error, :attempts => job.attempts + 1)
      job_say job, "FAILED (#{job.attempts} prior attempts) with #{error.class.name}: #{error.message}", 'error'
      reschedule(job)
    end
  end
end

Delayed::Worker.reset
