require 'mongoid'

module Delayed
  module Backend
    module Mongoid
      # This is the basic job object that is persisted to the database.  The work object stored in YAML format in the handler field.
      class Job
        include Delayed::Backend::Base
        include ::Mongoid::Document
        include ::Mongoid::Timestamps
        store_in :delayed_jobs
        
        field :priority, :type => Integer
        field :attempts, :type => Integer, :default => 0
        field :handler, :type => String
        field :last_error, :type => String
        field :run_at, :type => Time, :default => lambda{ return db_time_now }
        field :locked_at, :type => Time
        field :failed_at, :type => Time
        field :locked_by, :type => String
                
        scope :ready_to_run, lambda {|worker_name, max_run_time|
          where(:failed_at => nil, :run_at.lte => db_time_now).any_of({:locked_by => worker_name}, {:locked_at => nil}, {:locked_at.lte => (db_time_now - max_run_time)})
        }
        
        scope :by_priority, order_by(:priority.asc, :run_at.asc)
        
        def self.before_fork
          ::Mongoid.database.connection.close
        end

        def self.after_fork
          ::Mongoid.database.connection.connect
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          self.where(:locked_by => worker_name).each{ |job| job.update_attributes(:locked_by => nil, :locked_at => nil) }
        end

        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          scope = self.ready_to_run(worker_name, max_run_time)
          scope.and(:priority.gte => Worker.min_priority) if Worker.min_priority
          scope.and(:priority.lte => Worker.max_priority) if Worker.max_priority

          scope.by_priority.limit(limit).to_a
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now

          if locked_by != worker
            if (locked_at.blank? || locked_at < (now-max_run_time.to_i)) && run_at <= now
              return self.update_attributes :locked_at => now, :locked_by => worker
            end
          else
            return self.update_attributes :locked_at => now
          end
          
          return false
        end

        # Get the current time.
        def self.db_time_now
          # Only return Time.now if using bson_ext gem. It does not support ActiveSupport::TimeWithZone yet.
          return Time.now if defined?(CBson)
          if Time.zone
            Time.zone.now
          else
            Time.now
          end
        end
      end
    end
  end
end
