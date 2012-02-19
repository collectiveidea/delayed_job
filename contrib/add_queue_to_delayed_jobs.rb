class AddQueueToDelayedJobs < ActiveRecord::Migration
  def self.up
    add_column :delayed_jobs, :queue, :string
    remove_index :delayed_jobs, :delayed_jobs_priority
    add_index :delayed_jobs, [:priority, :run_at, :queue], :name => 'delayed_jobs_priority'
  end
  
  def self.down
    remove_index :delayed_jobs, :name => 'delayed_jobs_priority'
    add_index :delayed_jobs, [:priority, :run_at], :name => 'delayed_jobs_priority'
    remove_column :delayed_jobs, :queue
  end
end