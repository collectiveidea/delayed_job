require 'timeout'
require 'active_support/core_ext/numeric/time'

module Delayed
  class Worker
    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time, :default_priority, :sleep_delay, :logger
    self.sleep_delay = 5
    self.max_attempts = 25
    self.max_run_time = 4.hours
    self.default_priority = 0
    
    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    cattr_accessor :destroy_failed_jobs
    self.destroy_failed_jobs = true
    
    self.logger = if defined?(Merb::Logger)
      Merb.logger
    elsif defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER
    end

    # name_prefix is ignored if name is set directly
    attr_accessor :name_prefix
    
    cattr_reader :backend
    
    def self.backend=(backend)
      if backend.is_a? Symbol
        require "delayed/backend/#{backend}"
        backend = "Delayed::Backend::#{backend.to_s.classify}::Job".constantize
      end
      @@backend = backend
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end
    
    def self.guess_backend
      self.backend ||= if defined?(ActiveRecord)
        :active_record
      elsif defined?(MongoMapper)
        :mongo_mapper
      else
        logger.warn "Could not decide on a backend, defaulting to active_record"
        :active_record
      end
    end

    def initialize(options={})
      @quiet = options[:quiet]
      self.class.min_priority = options[:min_priority] if options.has_key?(:min_priority)
      self.class.max_priority = options[:max_priority] if options.has_key?(:max_priority)
      self.class.sleep_delay = options[:sleep_delay] if options.has_key?(:sleep_delay)
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
      say "Starting job worker"

      trap('TERM') { say 'Exiting...'; $exit = true }
      trap('INT')  { say 'Exiting...'; $exit = true }

      loop do
        result = nil

        realtime = Benchmark.realtime do
          result = work_off
        end

        count = result.sum

        break if $exit

        if count.zero?
          sleep(self.class.sleep_delay)
        else
          say "#{count} jobs processed at %.4f j/s, %d failed ..." % [count / realtime, result.last]
        end

        break if $exit
      end

    ensure
      Delayed::Job.clear_locks!(name)
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
        break if $exit # leave if we're exiting
      end

      return [success, failure]
    end
    
    def run(job)
      runtime =  Benchmark.realtime do
        Timeout.timeout(self.class.max_run_time.to_i) { job.invoke_job }
        job.destroy
      end
      say "#{job.name} completed after %.4f" % runtime
      return true  # did work
    rescue DeserializationError => error
      job.last_error = "{#{error.message}\n#{error.backtrace.join('\n')}"
      failed(job)
    rescue Exception => error
      handle_failed_job(job, error)
      return false  # work failed
    end
    
    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        job.run_at = time || job.reschedule_at
        job.unlock
        job.save!
      else
        say "PERMANENTLY removing #{job.name} because of #{job.attempts} consecutive failures.", Logger::INFO
        failed(job)
      end
    end

    def failed(job)
      begin
        if job.payload_object.respond_to? :on_permanent_failure
            say "Running on_permanent_failure hook"
            job.payload_object.on_permanent_failure
        end
      rescue DeserializationError
        # do nothing
      end
      
      self.class.destroy_failed_jobs ? job.destroy : job.update_attributes(:failed_at => Delayed::Job.db_time_now)
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
      job.last_error = error.message + "\n" + error.backtrace.join("\n")
      say "#{job.name} failed with #{error.class.name}: #{error.message} - #{job.attempts} failed attempts", Logger::ERROR
      reschedule(job)
    end
    
    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def reserve_and_run_one_job
      job = Delayed::Job.reserve(self)
      run(job) if job
    end
  end
end
