require 'ostruct'

# An in-memory backend suitable only for testing
module Delayed
  module Backend
    module Test
      class Job
        attr_accessor :priority
        attr_accessor :attempts
        attr_accessor :handler
        attr_accessor :last_error
        attr_accessor :run_at
        attr_accessor :locked_at
        attr_accessor :locked_by
        attr_accessor :failed_at
        
        include Delayed::Backend::Base

        def initialize(hash = {})
          self.attempts = 0
          self.priority = 0
          hash.each{|k,v| send(:"#{k}=", v)}
        end
        
        @queue = []
        def self.queue
          @queue
        end
        
        def self.count 
          queue.size
        end
        
        def self.clear_locks!(worker_name)
          queue.select{|j| j.locked_by == worker_name}.each {|j| j.locked_by = nil; j.locked_at = nil}
        end

        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          jobs = queue.select do |j| 
            j.run_at <= db_time_now && 
            (j.locked_at.nil? || j.locked_at < db_time_now - max_run_time || j.locked_by == worker_name) &&
            
            j.failed_at.nil?
          end
          
          jobs = jobs.select{|j| j.priority >= Worker.min_priority} if Worker.min_priority
          jobs = jobs.select{|j| j.priority <= Worker.max_priority} if Worker.max_priority
          job.sort_by{|j| [j.priority, j.run_at]}[0..limit-1]
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          if locked_by != worker
            # We don't own this job so we will update the locked_by name and the locked_at
            self.locked_at = now
            self.locked_by = worker
            return true
          end

          return false
        end

        def self.db_time_now
          Time.current
        end
        
        def save
          self.run_at ||= Time.current
          
          queue << self
          true
        end
        
        private
        
          def queue
            self.class.queue
          end

      end
    end
  end
end
