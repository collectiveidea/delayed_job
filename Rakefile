require 'bundler/setup'
Bundler::GemHelper.install_tasks

# The C extension (ext/delayed_job): `rake compile` builds it into lib/delayed.
if RUBY_ENGINE == 'jruby'
  task :compile # Nothing to build.
else
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('subreaper') do |ext|
    ext.ext_dir = 'ext/delayed_job'
    ext.lib_dir = 'lib/delayed'
  end
end

require 'rspec/core/rake_task'
desc 'Run the specs'
RSpec::Core::RakeTask.new do |r|
  r.verbose = false
end

task :test => :spec

require 'rubocop/rake_task'
RuboCop::RakeTask.new

task :spec => :compile
task :default => [:spec, :rubocop]
