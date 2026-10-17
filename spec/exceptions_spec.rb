require 'helper'

describe Delayed::WorkerTimeout do
  it 'reports the max run time in seconds' do
    Delayed::Worker.max_run_time = 5.seconds
    expect(Delayed::WorkerTimeout.new.message).to end_with('(Delayed::Worker.max_run_time is only 5 seconds)')
  end

  it 'uses the singular for one second' do
    Delayed::Worker.max_run_time = 1.second
    expect(Delayed::WorkerTimeout.new.message).to end_with('(Delayed::Worker.max_run_time is only 1 second)')
  end
end
