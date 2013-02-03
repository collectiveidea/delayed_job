require 'timeout'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/kernel'
require 'active_support/core_ext/enumerable'
require 'logger'
require 'benchmark'

module Delayed
  class Worker
    DEFAULT_SLEEP_DELAY      = 5
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = []
    DEFAULT_READ_AHEAD       = 5

    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time,
      :default_priority, :sleep_delay, :logger, :delay_jobs, :queues,
      :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete

    # Named queue into which jobs are enqueued by default
    cattr_accessor :default_queue_name

    cattr_reader :backend

    # name_prefix is ignored if name is set directly
    attr_accessor :name_prefix

    def self.reset
      self.sleep_delay      = DEFAULT_SLEEP_DELAY
      self.max_attempts     = DEFAULT_MAX_ATTEMPTS
      self.max_run_time     = DEFAULT_MAX_RUN_TIME
      self.default_priority = DEFAULT_DEFAULT_PRIORITY
      self.delay_jobs       = DEFAULT_DELAY_JOBS
      self.queues           = DEFAULT_QUEUES
      self.read_ahead       = DEFAULT_READ_AHEAD
    end

    reset

    # Add or remove plugins in this list before the worker is instantiated
    self.plugins = [Delayed::Plugins::ClearLocks]

    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    self.destroy_failed_jobs = true

    # By default, Signals INT and TERM set @exit, and the worker exits upon completion of the current job.
    # If you would prefer to raise a SignalException and exit immediately you can use this.
    # Be aware daemons uses TERM to stop and restart
    # false - No exceptions will be raised
    # :term - Will only raise an exception on TERM signals but INT will wait for the current job to finish
    # true - Will raise an exception on TERM and INT
    cattr_accessor :raise_signal_exceptions
    self.raise_signal_exceptions = false

    self.logger = if defined?(Rails)
      Rails.logger
    elsif defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER
    end

    def self.backend=(backend)
      if backend.is_a? Symbol
        require "delayed/serialization/#{backend}"
        require "delayed/backend/#{backend}"
        backend = "Delayed::Backend::#{backend.to_s.classify}::Job".constantize
      end
      @@backend = backend
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end

    def self.guess_backend
      warn "[DEPRECATION] guess_backend is deprecated. Please remove it from your code."
    end

    def self.before_fork
      unless @files_to_reopen
        @files_to_reopen = []
        ObjectSpace.each_object(File) do |file|
          @files_to_reopen << file unless file.closed?
        end
      end

      backend.before_fork
    end

    def self.after_fork
      # Re-open file handles
      @files_to_reopen.each do |file|
        begin
          file.reopen file.path, "a+"
          file.sync = true
        rescue ::Exception
        end
      end

      backend.after_fork
    end

    def self.lifecycle
      @lifecycle ||= Delayed::Lifecycle.new
    end

    def initialize(options={})
      @quiet = options.has_key?(:quiet) ? options[:quiet] : true

      [:min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :exit_on_complete].each do |option|
        self.class.send("#{option}=", options[option]) if options.has_key?(option)
      end

      self.plugins.each { |klass| klass.new }
    end

    # Every worker has a unique name which by default is the pid of the process. There are some
    # advantages to overriding this with something which survives worker retarts:  Workers can#
    # safely resume working on tasks which are locked by themselves. The worker will assume that
    # it crashed before.
    def name
      return @name unless @name.nil?
      "#{@name_prefix}host:#{Socket.gethostname} pid:#{Process.pid}" rescue "#{@name_prefix}pid:#{Process.pid}"
    end

    # Sets the name of the worker.
    # Setting the name to nil will reset the default worker name
    def name=(val)
      @name = val
    end

    def start
      trap('TERM') do
        say 'Exiting...'
        stop
        raise SignalException.new('TERM') if self.class.raise_signal_exceptions
      end

      trap('INT') do
        say 'Exiting...'
        stop
        raise SignalException.new('INT') if self.class.raise_signal_exceptions && self.class.raise_signal_exceptions != :term
      end

      say "Starting job worker"

      self.class.lifecycle.run_callbacks(:execute, self) do
        loop do
          self.class.lifecycle.run_callbacks(:loop, self) do
            @realtime = Benchmark.realtime do
              @result = work_off
            end
          end

          count = @result.sum

          if count.zero?
            if self.class.exit_on_complete
              say "No more jobs available. Exiting"
              break
            else
              sleep(self.class.sleep_delay) unless stop?
            end
          else
            say "#{count} jobs processed at %.4f j/s, %d failed ..." % [count / @realtime, @result.last]
          end

          break if stop?
        end
      end
    end

    def stop
      @exit = true
    end

    def stop?
      !!@exit
    end

    # Do num jobs and return stats on success/failure.
    # Exit early if interrupted.
    def work_off(num = 100)
      success, failure = 0, 0

      num.times do
        case reserve_and_run_one_job
        when true
            success += 1
        when false
            failure += 1
        else
          break  # leave if no work could be done
        end
        break if stop? # leave if we're exiting
      end

      return [success, failure]
    end

    def run(job)
      runtime =  Benchmark.realtime do
        Timeout.timeout(self.class.max_run_time.to_i, WorkerTimeout) { job.invoke_job }
        job.destroy
      end
      say "#{job.name} completed after %.4f" % runtime
      return true  # did work
    rescue DeserializationError => error
      job.last_error = "#{error.message}\n#{error.backtrace.join("\n")}"
      failed(job)
    rescue Exception => error
      self.class.lifecycle.run_callbacks(:error, self, job){ handle_failed_job(job, error) }
      return false  # work failed
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        time ||= job.reschedule_at
        job.run_at = time
        job.unlock
        job.save!
      else
        say "PERMANENTLY removing #{job.name} because of #{job.attempts} consecutive failures.", Logger::INFO
        failed(job)
      end
    end

    def failed(job)
      self.class.lifecycle.run_callbacks(:failure, self, job) do
        job.hook(:failure)
        self.class.destroy_failed_jobs ? job.destroy : job.fail!
      end
    end

    def say(text, level = Logger::INFO)
      text = "[Worker(#{name})] #{text}"
      puts text unless @quiet
      logger.add level, "#{Time.now.strftime('%FT%T%z')}: #{text}" if logger
    end

    def max_attempts(job)
      job.max_attempts || self.class.max_attempts
    end

  protected

    def handle_failed_job(job, error)
      job.last_error = "#{error.message}\n#{error.backtrace.join("\n")}"
      say "#{job.name} failed with #{error.class.name}: #{error.message} - #{job.attempts} failed attempts", Logger::ERROR
      reschedule(job)
    end

    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def reserve_and_run_one_job
      job = Delayed::Job.reserve(self)
      self.class.lifecycle.run_callbacks(:perform, self, job){ result = run(job) } if job
    end
  end

end
