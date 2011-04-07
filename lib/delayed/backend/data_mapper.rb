require 'dm-core'
require 'dm-observer'
require 'dm-aggregates'

module DataMapper
  module Resource
    module ClassMethods
      def load_for_delayed_job(id)
        find!(id)
      end
    end

    module InstanceMethods
      def dump_for_delayed_job
        "#{self.class};#{id}"
      end
    end
  end
end

module Delayed
  module Backend
    module DataMapper
      class Job
        include ::DataMapper::Resource
        include Delayed::Backend::Base
        
        storage_names[:default] = 'delayed_jobs'
        
        property :id,          Serial
        property :priority,    Integer, :default => 0, :index => :run_at_priority
        property :attempts,    Integer, :default => 0
        property :handler,     Text, :lazy => false
        property :run_at,      Time, :index => :run_at_priority
        property :locked_at,   Time, :index => true
        property :locked_by,   String
        property :failed_at,   Time
        property :last_error,  Text
                
        def self.db_time_now
          Time.now
        end
                
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          
          simple_conditions = { :run_at.lte => db_time_now, :limit => limit, :failed_at => nil, :order => [:priority.asc, :run_at.asc]  }

          # respect priorities
          simple_conditions[:priority.gte] = Worker.min_priority if Worker.min_priority
          simple_conditions[:priority.lte] = Worker.max_priority if Worker.max_priority
          
          # lockable 
          lockable = (
            # not locked or past the max time
            ( all(:locked_at => nil ) | all(:locked_at.lt => db_time_now - max_run_time)) |

            # OR locked by our worker
            all(:locked_by => worker_name))
            
          # plus some other boring junk 
          (lockable).all( simple_conditions )
        end
        
        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          all(:locked_by => worker_name).update(:locked_at => nil, :locked_by => nil)
        end
        
        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker = worker_name)

          now = self.class.db_time_now
          overtime = now - max_run_time
          
          # FIXME - this is a bit gross
          # DM doesn't give us the number of rows affected by a collection update
          # so we have to circumvent some niceness in DM::Collection here
          collection = locked_by != worker ?
            (self.class.all(:id => id, :run_at.lte => now) & ( self.class.all(:locked_at => nil) | self.class.all(:locked_at.lt => overtime) ) ) :
            self.class.all(:id => id, :locked_by => worker)
          
          attributes = collection.model.new(:locked_at => now, :locked_by => worker).dirty_attributes
          affected_rows = self.repository.update(attributes, collection)
            
          if affected_rows == 1
            self.locked_at = now
            self.locked_by = worker
            return true
          else
            return false
          end
        end
        
        # these are common to the other backends, so we provide an implementation
        def self.delete_all
          Delayed::Job.auto_migrate!
        end
        
        def self.find id
          get id
        end
        
        def update_attributes(attributes)
          attributes.each do |k,v|
            self[k] = v
          end
          self.save
        end
        
        
      end
      
      class JobObserver
        include ::DataMapper::Observer

        observe Job

        before :save do
          self.run_at ||= self.class.db_time_now
        end  

        after :create do
          scale_up
        end  
      end
    end
  end
end
