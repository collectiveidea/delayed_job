# -*- encoding: utf-8 -*-
require 'rubygems'
require 'bundler'
require 'bundler/setup'
require 'rspec/core/rake_task'

Bundler::GemHelper.install_tasks

desc 'Run the specs'
RSpec::Core::RakeTask.new do |r|
  r.verbose = false
end

task :default => :spec