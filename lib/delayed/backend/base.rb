module Delayed
  module Backend
    module Base
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        # Add a job to the queue
        def enqueue(*args)
          job_options = Delayed::Backend::JobPreparer.new(*args).prepare
          enqueue_job(job_options)
        end

        def enqueue_job(options)
          new(options).tap do |job|
            Delayed::Worker.lifecycle.run_callbacks(:enqueue, job) do
              job.hook(:enqueue)
              Delayed::Worker.delay_job?(job) ? job.save : job.invoke_job
            end
          end
        end

        def reserve(worker, max_run_time = Worker.max_run_time)
          # We get up to 5 jobs from the db. In case we cannot get exclusive access to a job we try the next.
          # this leads to a more even distribution of jobs across the worker processes
          find_available(worker.name, worker.read_ahead, max_run_time).detect do |job|
            job.lock_exclusively!(max_run_time, worker.name)
          end
        end

        # Reserves up to one job per worker; returns [worker, job] pairs in
        # workers' order, each job locked under its paired worker's name.
        # The default calls #reserve per worker and stops at the first miss;
        # backends may override with a single query, used when
        # Worker.batch_reserve is set.
        def reserve_batch(workers, max_run_time = Worker.max_run_time)
          reserved = []
          workers.each do |worker|
            job = reserve(worker, max_run_time)
            break unless job
            reserved << [worker, job]
          end
          reserved
        rescue StandardError => error
          # Return the jobs already locked rather than strand them; a
          # persistent error recurs on the next reservation.
          raise if reserved.empty?
          Delayed::Worker.thread_error(error, :context => 'Reservation')
          reserved
        end

        # True if reserve_batch can return a partial batch while jobs remain
        # (e.g. lost races to other processes); the Dispatcher then polls
        # again at once instead of sleeping sleep_delay.
        def partial_batch_may_leave_jobs?
          false
        end

        # Jobs locked by the named worker, or by any of an array of names (in
        # one query: a process has one per thread and prefetch slot), or nil
        # if unsupported. Needed to recover a dead process's jobs
        # (Worker.recover_jobs_of); without it their locks are only cleared.
        # Backends' clear_locks! takes a name or an array of names likewise.
        def locked_jobs(_worker_names)
          nil
        end

        # True if the backend implements #touch_locks and treats locks older
        # than reserve's max_run_time as abandoned (Worker.lock_heartbeat_interval).
        def lock_heartbeats?
          false
        end

        # Sets locked_at to now on the named workers' jobs; returns the count.
        def touch_locks(_worker_names)
          raise NotImplementedError, "#{name} does not support lock heartbeats"
        end

        # Silences query logging for the block, on the calling thread only.
        # The default handles ActiveRecord::Base.logger; backends using
        # another logger (e.g. Mongo's) override it.
        def silence_logging(&block)
          logger = defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.logger
          return yield unless logger.respond_to?(:silence)
          logger.silence(::Logger::WARN, &block)
        end

        # Allow the backend to attempt recovery from reserve errors
        def recover_from(_error); end

        # Hook method that is called before a new worker is forked
        def before_fork; end

        # Hook method that is called after a new worker is forked
        def after_fork; end

        def work_off(num = 100)
          warn '[DEPRECATION] `Delayed::Job.work_off` is deprecated. Use `Delayed::Worker.new.work_off instead.'
          Delayed::Worker.new.work_off(num)
        end
      end

      attr_reader :error

      def error=(error)
        @error = error
        self.last_error = "#{error.message}\n#{error.backtrace.join("\n")}" if respond_to?(:last_error=)
      end

      def failed?
        !!failed_at
      end
      alias_method :failed, :failed?

      ParseObjectFromYaml = %r{!ruby/\w+:([^\s]+)} # rubocop:disable Naming/ConstantName

      # Falls back to the class named in the handler if the payload can't load.
      def name
        @name ||= payload_object.respond_to?(:display_name) ? payload_object.display_name : payload_object.class.name
      rescue DeserializationError
        match = ParseObjectFromYaml.match(handler.to_s)
        match ? match[1] : 'Unknown'
      end

      def payload_object=(object)
        @payload_object = object
        self.handler = object.to_yaml
      end

      def payload_object
        @payload_object ||= YAML.load_dj(handler)
      rescue TypeError, LoadError, NameError, ArgumentError, SyntaxError, Psych::SyntaxError => error
        raise DeserializationError, "Job failed to load: #{error.message}. Handler: #{handler.inspect}"
      end

      def invoke_job
        Delayed::Worker.lifecycle.run_callbacks(:invoke_job, self) do
          hook :before
          # Hooks must not be interrupted, only perform.
          Delayed::Dispatcher.interruptible { payload_object.perform }
          hook :success
        rescue Exception => error # rubocop:disable Lint/RescueException
          hook :error, error
          raise error
        ensure
          hook :after
        end
      end

      # Unlock this job (note: not saved to DB)
      def unlock
        self.locked_at    = nil
        self.locked_by    = nil
      end

      def hook(name, *args)
        if payload_object.respond_to?(name)
          method = payload_object.method(name)
          method.arity.zero? ? method.call : method.call(self, *args)
        end
      rescue DeserializationError # rubocop:disable Lint/SuppressedException
      end

      # Unloadable payloads (e.g. recovered from a dead worker) get the default.
      def reschedule_at
        if payload_object.respond_to?(:reschedule_at)
          payload_object.reschedule_at(self.class.db_time_now, attempts)
        else
          default_reschedule_at
        end
      rescue DeserializationError
        default_reschedule_at
      end

      def max_attempts
        payload_object.max_attempts if payload_object.respond_to?(:max_attempts)
      rescue DeserializationError
        nil
      end

      def max_run_time
        return unless payload_object.respond_to?(:max_run_time)
        return unless (run_time = payload_object.max_run_time)

        if run_time > Delayed::Worker.max_run_time
          Delayed::Worker.max_run_time
        else
          run_time
        end
      end

      def destroy_failed_jobs?
        payload_object.respond_to?(:destroy_failed_jobs?) ? payload_object.destroy_failed_jobs? : Delayed::Worker.destroy_failed_jobs
      rescue DeserializationError
        Delayed::Worker.destroy_failed_jobs
      end

      def fail!
        self.failed_at = self.class.db_time_now
        save!
      end

    protected

      def set_default_run_at
        self.run_at ||= self.class.db_time_now
      end

      def default_reschedule_at
        self.class.db_time_now + (attempts**4) + 5
      end

      # Call during reload operation to clear out internal state
      def reset
        @payload_object = nil
        @name = nil
      end
    end
  end
end
