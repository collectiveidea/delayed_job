# A minimal Active Record backend on an SQLite file, so that several real
# processes (a forking launcher and its children) share one job table.
# Used by the process-level specs, in the spec process and in subprocesses.
require 'active_record'
require 'delayed_job'

# Waits for a locked SQLite database in Ruby (sleeping, so other threads
# run), as Rails 8 does. Rails 7.2 sets the C-level busy_timeout instead,
# which keeps the GVL while it waits: a thread waiting for the lock then
# stops the thread holding it from committing, until the timeout raises
# "database is locked" (e.g. a lock heartbeat waiting on a worker thread).
module SqliteBusyHandlerInRuby
  def configure_connection
    super
    raw = @raw_connection
    raw.busy_handler_timeout = self.class.type_cast_config_to_integer(@config[:timeout]) if @config[:timeout] && raw.respond_to?(:busy_handler_timeout=)
  end
end
if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter) || (begin
  require 'active_record/connection_adapters/sqlite3_adapter'
rescue LoadError
  false
end)
  ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteBusyHandlerInRuby)
end

module Delayed
  module Backend
    module SqliteFile
      class Job < ActiveRecord::Base
        include Delayed::Backend::Base
        self.table_name = 'delayed_jobs'

        before_save :set_default_run_at

        def self.connect(path)
          establish_connection(:adapter => 'sqlite3', :database => path, :pool => 20, :timeout => 10_000)
          Run.establish_connection(:adapter => 'sqlite3', :database => path, :pool => 20, :timeout => 10_000)
        end

        def self.create_schema
          connection.create_table :delayed_jobs, :force => true do |t|
            t.integer :priority, :default => 0, :null => false
            t.integer :attempts, :default => 0, :null => false
            t.text :handler, :null => false
            t.text :last_error
            t.datetime :run_at, :locked_at, :failed_at
            t.string :locked_by, :queue
            t.timestamps :null => true
          end
          connection.create_table :runs, :force => true do |t|
            t.string :key
            t.integer :pid
            t.string :worker
            t.float :started, :finished
          end
        end

        def self.db_time_now
          Time.now.utc
        end

        def self.before_fork
          connection_handler.clear_all_connections!(:all)
        rescue ArgumentError
          connection_handler.clear_all_connections!
        end

        def self.after_fork
          connection_handler.clear_all_connections!(:all)
        rescue ArgumentError
          connection_handler.clear_all_connections!
        end

        def self.lock_heartbeats?
          true
        end

        def self.touch_locks(names)
          where(:locked_by => names).update_all(:locked_at => db_time_now)
        end

        def self.locked_jobs(name)
          where(:locked_by => name).to_a
        end

        def self.clear_locks!(name)
          where(:locked_by => name).update_all(:locked_by => nil, :locked_at => nil)
        end

        def self.find_available(name, limit, max_run_time)
          now = db_time_now
          scope = where('run_at <= ? AND failed_at IS NULL AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?)', now, now - max_run_time, name)
          scope = scope.where('priority >= ?', Worker.min_priority) if Worker.min_priority
          scope = scope.where('priority <= ?', Worker.max_priority) if Worker.max_priority
          scope = scope.where(:queue => Worker.queues) if Worker.queues.any?
          scope.order(:priority, :run_at, :id).limit(limit).to_a
        end

        def lock_exclusively!(max_run_time, name)
          now = self.class.db_time_now
          locked = self.class.where('id = ? AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?)', id, now - max_run_time, name).
                   update_all(:locked_at => now, :locked_by => name)
          return false unless locked == 1
          self.locked_at = now
          self.locked_by = name
          clear_changes_information
          true
        end

        def destroy_if_locked_by(name)
          self.class.where(:id => id, :locked_by => name).delete_all == 1
        end

        def save_if_locked_by(name)
          self.updated_at = self.class.db_time_now
          saved = self.class.where(:id => id, :locked_by => name).update_all(attributes.except('id')) == 1
          clear_changes_information if saved
          saved
        end

        def reload(*)
          reset
          super
        end
      end

      # One row per job run, written by the jobs in jobs.rb.
      class Run < ActiveRecord::Base
        self.table_name = 'runs'
      end
    end
  end
end
