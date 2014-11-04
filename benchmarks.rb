require 'spec/helper'
require 'logger'
require 'benchmark'

# Delayed::Worker.logger = Logger.new('/dev/null')

Benchmark.bm(10) do |x|
  Delayed::Job.delete_all
  n = 10_000
  n.times { 'foo'.delay.length }

  x.report { Delayed::Worker.new(quiet: true).work_off(n) }
end
