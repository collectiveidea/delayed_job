$:.unshift(File.dirname(__FILE__) + '/lib')
require 'rubygems'
require 'logger'
require 'delayed_job'
require 'benchmark'

RAILS_ENV = 'test'

Delayed::Worker.logger = Logger.new('/dev/null')

BACKENDS = []
Dir.glob("#{File.dirname(__FILE__)}/spec/setup/*.rb") do |backend|
  begin
    backend = File.basename(backend, '.rb')
    require "spec/setup/#{backend}"
    BACKENDS << backend.to_sym
  rescue LoadError
    puts "Unable to load #{backend} backend! #{$!}"
  end
end


Benchmark.bm(10) do |x|
  BACKENDS.each do |backend|
    require "spec/setup/#{backend}"
    Delayed::Worker.backend = backend

    n = 10000
    n.times { "foo".delay.length }

    x.report(backend.to_s) { Delayed::Worker.new(:quiet => true).work_off(n) }
  end
end
