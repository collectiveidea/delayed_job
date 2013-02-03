unless ENV['CI']
  require 'simplecov'
  SimpleCov.start
end

require 'bundler/setup'
require 'logger'

require 'action_mailer'
require 'active_support/dependencies'
require 'active_record'

require 'delayed_job'
require 'delayed/backend/shared_spec'

Delayed::Worker.logger = Logger.new('/tmp/dj.log')
ENV['RAILS_ENV'] = 'test'

Delayed::Worker.backend = :test

# Add this directory so the ActiveSupport autoloading works
ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)

# Add this to simulate Railtie initializer being executed
ActionMailer::Base.send(:extend, Delayed::DelayMail)


# Used to test interactions between DJ and an ORM
ActiveRecord::Base.establish_connection :adapter => 'sqlite3', :database => ':memory:'
ActiveRecord::Base.logger = Delayed::Worker.logger
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :stories, :primary_key => :story_id, :force => true do |table|
    table.string :text
    table.boolean :scoped, :default => true
  end
end

class Story < ActiveRecord::Base
  self.primary_key = 'story_id'
  def tell; text; end
  def whatever(n, _); tell*n; end
  default_scope where(:scoped => true)

  handle_asynchronously :whatever
end

RSpec.configure do |config|
  config.after(:each) do
    Delayed::Worker.reset
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
