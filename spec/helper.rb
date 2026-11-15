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
  skip '/spec/'
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
ActiveRecord::Base # rubocop:disable Lint/Void
# Load Active Record up front, as Rails does in production: specs use it from
# several threads, and TruffleRuby can let one thread see a class another is
# still autoloading (e.g. ActiveRecord::PredicateBuilder, without #initialize).
ActiveRecord.eager_load!

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
  # Process-level specs load these files explicitly, in subprocesses too
  loader.ignore File.join(File.dirname(__FILE__), 'processes')
  loader.ignore File.join(File.dirname(__FILE__), 'helpers') # Required below.
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

# Specs collect log lines, events and errors in Concurrent::Arrays: the stubs
# and callbacks appending to them run on worker and heartbeat threads, in
# parallel on JRuby, where Array#<< can lose entries.
require 'concurrent/array'

Dir[File.join(__dir__, 'helpers', '*.rb')].sort.each { |file| require file }

RSpec.configure do |config|
  config.include LogHelper
  config.include ThreadHelper
  config.include EventHelper

  # Each example starts with no job in the test backend: one left behind by
  # an earlier example (e.g. a job that never got to run) would otherwise be
  # run by the next dispatcher, which may then wait for it forever.
  config.before(:each) do
    Delayed::Backend::Test::Job.delete_all
  end

  config.after(:each) do
    Delayed::Worker.reset
  end

  # Declared after the reset above, so it runs first (after hooks run in
  # reverse): dispatchers stop under the example's settings.
  config.after(:each) do
    stop_running_dispatchers
    unsubscribe_all
  end

  # Specs that fork (real worker processes, children of jobs) can't run where
  # there is no fork, e.g. JRuby.
  config.define_derived_metadata(:file_path => %r{/spec/processes/}) { |meta| meta[:fork] = true }
  config.filter_run_excluding :fork => true unless Process.respond_to?(:fork)
  # Launcher specs stub out the fork itself: let them run the forking paths
  # there too (the guard has specs of its own).
  unless Process.respond_to?(:fork)
    config.before(:each) do |example|
      allow_any_instance_of(Delayed::Launcher::Forking).to receive(:fork_available?).and_return(true) unless example.metadata[:fork_guard]
    end
  end

  # The launcher's signal traps log from a thread of their own: let those
  # finish within their example, before its test doubles expire.
  config.after(:each) do
    Thread.list.each do |thread|
      next if thread == Thread.current || thread.status == 'sleep' || !thread.inspect.include?('launcher/forking.rb')
      thread.join(1)
    end
  end

  # A hung example (a deadlock, a wait with no timeout) would otherwise run
  # until CI's job timeout without a word on where it stuck. Past
  # SPEC_TIMEOUT seconds (hooks included), print it and every thread's
  # backtrace, then fail it; if it doesn't stop, end the run.
  spec_timeout = Integer(ENV.fetch('SPEC_TIMEOUT', 180))
  config.around(:each) do |example|
    main = Thread.current
    done = Queue.new
    watchdog = Thread.new do
      Thread.current.thread_variable_set(:fork_safe, true)
      next unless done.pop(:timeout => spec_timeout).nil?
      warn "\nExample still running after #{spec_timeout}s: #{example.location} #{example.full_description}"
      (Thread.list - [Thread.current]).each { |thread| warn "#{thread.inspect}\n  #{thread.backtrace.to_a.join("\n  ")}" }
      main.raise Timeout::Error, "example still running after #{spec_timeout}s (backtraces on stderr)"
      next unless done.pop(:timeout => 30).nil?
      warn 'The example did not stop; ending the run'
      exit!(1)
    end
    watchdog.name = 'Spec watchdog'
    begin
      example.run
    ensure
      done << true
      watchdog.join
    end
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
