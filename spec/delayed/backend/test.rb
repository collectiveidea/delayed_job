require 'monitor'

# An in-memory backend suitable only for testing. Tries to behave as if it were an ORM.
module Delayed
  module Backend
    module Test
      class Job
        attr_accessor :id, :priority, :attempts, :handler, :last_error, :run_at, :locked_at, :locked_by, :failed_at, :queue

        include Delayed::Backend::Base

        # The id counter: class-level only (an instance reader would make every
        # job report the last id given out).
        cattr_accessor :id, :instance_accessor => false
        self.id = 0

        # Guards the in-memory job list so the backend can be used by
        # multi-threaded workers. A Monitor is used since it is reentrant.
        LOCK = Monitor.new

        def self.synchronize(&block)
          LOCK.synchronize(&block)
        end

        def initialize(hash = {})
          self.attempts = 0
          self.priority = 0
          self.id = self.class.synchronize { self.class.id += 1 }
          hash.each { |k, v| send(:"#{k}=", v) }
        end

        # Created up front: a lazy `@jobs ||= []` could hand two threads
        # different lists (JRuby).
        @jobs = []

        def self.all
          @jobs
        end

        def self.count
          synchronize { all.size }
        end

        def self.find(id)
          synchronize { all.detect { |job| job.id == id } } || raise(ArgumentError, "no job with id #{id}")
        end

        def self.delete_all
          synchronize { all.clear }
        end

        def self.create(attrs = {})
          new(attrs).tap do |o|
            o.save
          end
        end

        def self.create!(*args)
          create(*args)
        end

        # A worker name, or an array of names.
        def self.locked_jobs(worker_names)
          synchronize { locked_by_any(worker_names) }
        end

        def self.clear_locks!(worker_names)
          synchronize { locked_by_any(worker_names).each(&:unlock) }
        end

        def self.locked_by_any(worker_names)
          names = Array(worker_names)
          all.select { |j| names.include?(j.locked_by) }
        end
        private_class_method :locked_by_any

        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          jobs = synchronize do
            all.select do |j|
              j.run_at <= db_time_now &&
                (j.locked_at.nil? || j.locked_at < db_time_now - max_run_time || j.locked_by == worker_name) &&
                !j.failed?
            end
          end
          jobs.select! { |j| j.priority <= Worker.max_priority } if Worker.max_priority
          jobs.select! { |j| j.priority >= Worker.min_priority } if Worker.min_priority
          jobs.select! { |j| Worker.queues.include?(j.queue) } if Worker.queues.any?
          jobs.sort_by! { |j| [j.priority, j.run_at] }[0..limit - 1]
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        # The check and the update are atomic, so concurrent workers
        # (threads) can never both lock the same job.
        def lock_exclusively!(max_run_time, worker)
          self.class.synchronize do
            now = self.class.db_time_now
            return true if locked_by == worker
            return false if locked_at && locked_at >= now - max_run_time

            # We don't own this job so we will update the locked_by name and the locked_at
            self.locked_at = now
            self.locked_by = worker
            true
          end
        end

        def self.db_time_now
          Time.current
        end

        class << self
          # Called with each job about to be destroyed (specs): a hook
          # rather than a stub, as rspec-mocks stubs aren't thread-safe.
          attr_accessor :before_destroy
        end

        def destroy
          hook = self.class.before_destroy
          hook.call(self) if hook
          self.class.synchronize { self.class.all.delete(self) }
        end

        def save
          self.run_at ||= Time.current

          self.class.synchronize do
            self.class.all << self unless self.class.all.include?(self)
          end
          true
        end

        def save!
          save
        end

        def reload
          reset
          self
        end
      end
    end
  end
end
