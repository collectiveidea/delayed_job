class CreateDelayedJobsCompletedJobs < ActiveRecord::Migration
  def self.up
    create_table :delayed_jobs_completed_jobs, :force => true do |table|
      table.integer  :priority, :default => 0      # Allows some jobs to jump to the front of the queue
      table.integer  :attempts, :default => 0      # Provides for retries, but still fail eventually.
      table.text     :handler                      # YAML-encoded string of the object that will do work
      table.text     :last_error                   # reason for last failure (See Note below)
      table.datetime :run_at                       # When to run. Could be Time.zone.now for immediately, or sometime in the future.
      table.string   :locked_by                    # Who is working on this object (if locked)
      table.timestamps
    end

    add_index :delayed_jobs_completed_jobs, [:priority, :run_at], :name => 'delayed_jobs_completed_jobs_priority'
  end

  def self.down
    drop_table :delayed_jobs_completed_jobs
  end
end