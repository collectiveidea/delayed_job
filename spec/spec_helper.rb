$:.unshift(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'bundler/setup'
# Bundler.require
require 'rspec'
require 'logger'

# require 'rails'
require 'active_record'
require 'action_mailer'

require 'delayed_job'

require 'sample_jobs'

# common support libs
Dir[ File.join(File.dirname(__FILE__), 'support', '**', '*.rb') ].each { |f| require f }

Delayed::Worker.logger = Logger.new('/tmp/dj.log')
# ENV['RAILS_ENV'] = 'test'

ActiveRecord::Base.establish_connection( 'adapter' => 'sqlite3', 'database' => ':memory:' )
ActiveRecord::Base.logger = Delayed::Worker.logger
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :delayed_jobs, :force => true do |table|
    table.integer  :priority, :default => 0
    table.integer  :attempts, :default => 0
    table.text     :handler
    table.text     :last_error
    table.datetime :run_at
    table.datetime :locked_at
    table.datetime :failed_at
    table.string   :locked_by
    table.timestamps
  end

  add_index :delayed_jobs, [:priority, :run_at], :name => 'delayed_jobs_priority'

  create_table :stories, :primary_key => :story_id, :force => true do |table|
    table.string :text
  end
end

# Purely useful for test cases...
class Story < ActiveRecord::Base
  set_primary_key :story_id
  def tell; text; end
  def whatever(n, _); tell*n; end

  handle_asynchronously :whatever
end

Delayed::Worker.backend = :active_record

# Add this directory so the ActiveSupport autoloading works
ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)

# Add this to simulate Railtie initializer being executed
ActionMailer::Base.send(:extend, Delayed::DelayMail)


RSpec.configure do |config|
end
