require 'simplecov'
require 'simplecov-lcov'

SimpleCov::Formatter::LcovFormatter.config do |c|
  c.report_with_single_file = true
  c.single_report_path = 'coverage/lcov.info'
end
SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::LcovFormatter
]

SimpleCov.start do
  # SimpleCov 1.0 renamed add_filter to skip, and only SimpleCov 1.x, which
  # requires Ruby 3.2, measures branch and method coverage
  if respond_to?(:skip)
    skip '/spec/'
    # Shared examples for backend gems, not library code
    skip 'lib/delayed/backend/shared_spec.rb'

    # JRuby can't measure branch or method coverage, and its line coverage
    # is unreliable without --debug, so only enforce thresholds on CRuby
    if RUBY_ENGINE == 'ruby'
      coverage :line, :minimum => 100
      coverage :branch, :minimum => 100
      coverage :method, :minimum => 100
    end
  else
    add_filter '/spec/'
  end
end

require 'logger'
require 'rspec'

require 'action_mailer'
require 'active_record'

require 'delayed_job'
require 'delayed/backend/shared_spec'

if ENV['DEBUG_LOGS']
  Delayed::Worker.logger = Logger.new(STDOUT)
else
  require 'tempfile'

  tf = Tempfile.new('dj.log')
  Delayed::Worker.logger = Logger.new(tf.path)
  tf.unlink
end
ENV['RAILS_ENV'] = 'test'

# Trigger AR to initialize
ActiveRecord::Base # rubocop:disable Void

module Rails
  def self.root
    '.'
  end
end

Delayed::Worker.backend = :test

if ActiveSupport::VERSION::MAJOR < 7
  require 'active_support/dependencies'

  # Add this directory so the ActiveSupport autoloading works
  ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)
else
  # Rails 7 dropped classic dependency auto-loading. This does a basic
  # zeitwerk setup to test against zeitwerk directly as the Rails zeitwerk
  # setup is intertwined in the application boot process.
  require 'zeitwerk'

  loader = Zeitwerk::Loader.new
  loader.push_dir File.dirname(__FILE__)
  loader.setup
end

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
  def tell
    text
  end

  def whatever(n, _)
    tell * n
  end
  default_scope { where(:scoped => true) }

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
