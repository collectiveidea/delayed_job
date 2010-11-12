require 'active_record'

class ActiveRecord::Base
  yaml_as "tag:ruby.yaml.org,2002:ActiveRecord"
  
  def self.yaml_new(klass, tag, val)
    klass.find(val['attributes']['id'])
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def to_yaml_properties
    ['@attributes']
  end
end

module Delayed
  module Backend
    module ActiveRecord
      # A job object that is persisted to the database.
      # Contains the work object as a YAML field.
      class Job < ::ActiveRecord::Base
        include Delayed::Backend::Base
        set_table_name :delayed_jobs
        
        before_save :set_default_run_at


        named_scope :ready_to_run, lambda {|worker_name, max_run_time|
          {:conditions => ['(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR locked_by = ?) AND failed_at IS NULL', db_time_now, db_time_now - max_run_time, worker_name]}
        }
        named_scope :by_priority, :order => 'priority ASC, run_at ASC'

        named_scope :locked_by_worker, lambda{|worker_name, max_run_time|
          {:conditions => ['locked_by = ? AND locked_at > ?', worker_name, db_time_now - max_run_time]}
        }
        
        def self.after_fork
          ::ActiveRecord::Base.connection.reconnect!
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          update_all("locked_by = null, locked_at = null", ["locked_by = ?", worker_name])
        end

        def self.jobs_available_to_worker(worker_name, max_run_time)
          scope = self.ready_to_run(worker_name, max_run_time)
          scope = scope.scoped(:conditions => ['priority >= ?', Worker.min_priority]) if Worker.min_priority
          scope = scope.scoped(:conditions => ['priority <= ?', Worker.max_priority]) if Worker.max_priority
          scope.by_priority
        end
        
        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)          
          ::ActiveRecord::Base.silence do
            jobs_available_to_worker(worker_name, max_run_time).all(:limit => limit)
          end
        end

        # Returns a locked job or nil.  Serializes worker lock attempts on db.
        def self.find_and_lock!(worker_name, max_run_time)
          affected_rows = update_all(["locked_at = ?, locked_by = ?", db_time_now, worker_name], jobs_available_to_worker(worker_name, max_run_time).scope(:find)[:conditions], :limit => 1)
          if affected_rows == 1
            locked_by_worker(worker_name, max_run_time).first
          else
            nil
          end
        end
        
        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          affected_rows = if locked_by != worker
            # We don't own this job so we will update the locked_by name and the locked_at
            self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?) and (run_at <= ?)", id, (now - max_run_time.to_i), now])
          else
            # We already own this job, this may happen if the job queue crashes.
            # Simply resume and update the locked_at
            self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
          end
          if affected_rows == 1
            self.locked_at    = now
            self.locked_by    = worker
            return true
          else
            return false
          end
        end

        # Get the current time (GMT or local depending on DB)
        # Note: This does not ping the DB to get the time, so all your clients
        # must have syncronized clocks.
        def self.db_time_now
          if Time.zone
            Time.zone.now
          elsif ::ActiveRecord::Base.default_timezone == :utc
            Time.now.utc
          else
            Time.now
          end
        end

      end
    end
  end
end
