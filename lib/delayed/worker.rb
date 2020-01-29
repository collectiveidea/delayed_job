require 'active_support/core_ext/numeric/time'

module Delayed
  class Worker
    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time, :sleep_delay, :logger, :queue
    self.sleep_delay = 5
    self.max_attempts = 25
    self.max_run_time = 4.hours

    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    cattr_accessor :destroy_failed_jobs
    self.destroy_failed_jobs = true

    self.logger = if defined?(Merb::Logger)
                    Merb.logger
                  elsif defined?(Rails.logger)
                    Rails.logger
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
      self.queue = options.has_key?(:queue) ? options[:queue] : nil
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
      say "*** Starting job worker #{name}"

      # Have the loggers flush the buffer after every message, otherwise
      # log messages can be lost when the forked worker process exits.
      # Only matters for production where the rails buffered logger
      # has auto_flushing set to 1000 by default.
      Rails.logger.auto_flushing = true if Rails.logger.respond_to?(:auto_flushing=)
      Delayed::Worker.logger.auto_flushing = true if Delayed::Worker.logger.respond_to?(:auto_flushing=)

      trap('TERM') { say 'Exiting...'; $exit = true }
      trap('INT') { say 'Exiting...'; $exit = true }

      #[terry] perf
      #PerfTools::CpuProfiler.start("/tmp/dj-#{Process.pid}") do
      loop do
        result = nil

        realtime = Benchmark.realtime do
          result = work_off
        end

        count = result.sum

        break if $exit

        if count.zero?
          sleep(@@sleep_delay)
        else
          say "#{count} jobs processed at %.4f j/s, %d failed ..." % [count / realtime, result.last]
        end

        break if $exit
      end
        #end #[terry] perf

    ensure
      Delayed::Job.clear_locks!(name)
    end

    def forked!
      # Reseed RNG after fork - see [SA-9726] & https://www.ruby-forum.com/topic/970111
      srand
      ActiveRecord::Base.connection.reconnect!
      Rails.cache.instance_variable_get(:@data).reset
      Mongoid.default_session.disconnect

      # Ensure the worker re-populates the guid bucket so that guids are not reused
      UUID.send(:class_variable_get, :@@guid_bucket).try(:clear)
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
            break # leave if no work could be done
        end
        break if $exit # leave if we're exiting
      end

      return [success, failure]
    end

    def run(job)
      success = false
      runtime = Benchmark.realtime do
        begin
          if ENV['nofork']
            invoke_job(job)
            success = true
          else
            fork do
              forked!
              begin
                invoke_job(job)
              rescue Exception => e
                handle_failed_job(job, e)
                Kernel.exit!(1) # work failed
              end
              Kernel.exit!(0)
            end
            Process.wait
            raise "Forked worker process exited abnormally" if !$?.exited?
            success = ($?.exitstatus == 0)
          end
        rescue Exception => e
          handle_failed_job(job, e)
        end
      end
      # TODO: warn if runtime > max_run_time ?
      say "* [JOB] #{name} completed after %.4f" % runtime
      success
    end

    def invoke_job(job)
      SchoolAdmin::Delayed.with_current_job(job) do
        Timeout.timeout(self.class.max_run_time.to_i) { job.invoke_job }
      end
      job.destroy
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < self.class.max_attempts
        time ||= Job.db_time_now + (job.attempts ** 4) + 5
        job.run_at = time
        job.unlock
        job.save!
      else
        say "* [JOB] PERMANENTLY removing #{job.name} because of #{job.attempts} consecutive failures.", Logger::INFO

        if job.payload_object.respond_to? :on_permanent_failure
          say "* [JOB] Running on_permanent_failure hook"
          job.payload_object.on_permanent_failure
        end

        self.class.destroy_failed_jobs ? job.destroy : job.update_attributes(:failed_at => Delayed::Job.db_time_now)
      end
    end

    def say(text, level = Logger::INFO)
      puts text unless @quiet
      logger.add level, "#{Time.now.strftime('%FT%T%z')}: #{text}" if logger
    end

    protected

    def handle_failed_job(job, error)
      job.last_error = error.message + "\n" + error.backtrace.join("\n")
      say "* [JOB] #{name} failed with #{error.class.name}: #{error.message} - #{job.attempts} failed attempts", Logger::ERROR

      EdgeCaseAlert.alert(
        canonical_name: "dj_failed - #{job.name}",
        body: "DJ Job #{job.name} (id:#{job.id}) FAILED! #{error.message}",
        exception: error
      )
      reschedule(job)
    end

    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def reserve_and_run_one_job

      # We get up to 5 jobs from the db. In case we cannot get exclusive access to a job we try the next.
      # this leads to a more even distribution of jobs across the worker processes
      job = Delayed::Job.find_available(name, 5, self.class.max_run_time).detect do |job|
        if job.lock_exclusively!(self.class.max_run_time, name)
          say "* [Worker(#{name})] acquired lock on #{job.name}"
          true
        else
          say "* [Worker(#{name})] failed to acquire exclusive lock for #{job.name}", Logger::WARN
          false
        end
      end

      System.reset_current_customer!
      run(job) if job
    end
  end
end
