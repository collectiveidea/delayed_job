$:.unshift(File.dirname(__FILE__) + '/../lib')

require 'rubygems'
require 'bundler/setup'
require 'rspec'
require 'logger'

require 'rails'
require 'active_record'
require 'action_mailer'

require 'delayed_job'
require 'delayed/backend/shared_spec'

Delayed::Worker.logger = Logger.new('/tmp/dj.log')
ENV['RAILS_ENV'] = 'test'

config = YAML.load(File.read('spec/database.yml'))
ActiveRecord::Base.configurations = {'test' => config['mysql']}
ActiveRecord::Base.establish_connection
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
    table.boolean :scoped, :default => true
  end
end

# Purely useful for test cases...
class Story < ActiveRecord::Base
  set_primary_key :story_id
  def tell; text; end
  def whatever(n, _); tell*n; end
  default_scope where(:scoped => true)

  handle_asynchronously :whatever
end

Delayed::Worker.backend = :active_record

# Add this directory so the ActiveSupport autoloading works
ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)

# Add this to simulate Railtie initializer being executed
ActionMailer::Base.send(:extend, Delayed::DelayMail)
