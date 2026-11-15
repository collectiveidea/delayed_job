require 'helper'
require_relative 'helpers'

# A signal reaching a child process right after the fork, while it still
# runs the launcher's inherited signal traps.
describe 'A child process signalled before it installs its own traps', :processes do
  include ProcessHelpers

  it 'stops once started, and leaves its siblings alone' do
    pid, reader = spawn_launcher(:processes => 2, :capture_delay => 1.5, :worker => {:sleep_delay => 0.1})
    output = +''
    wait_for(10) { (output << read_available(reader)).scan(/capturing signals/).size == 2 }
    children = output.scan(/Child process (delayed_job\.\d) \(pid (\d+)\) started/).to_h
    victim = children['delayed_job.1'].to_i # Its inherited launcher state knows delayed_job.0.
    Process.kill('TERM', victim)
    wait_for(10) { (output << read_available(reader)) =~ /Child process delayed_job\.1 \(pid #{victim}\) exited: pid \d+ exit 0/ }
    sleep 1 # delayed_job.0 would have been signalled by now.
    output << read_available(reader)
    Process.kill('TERM', pid)
    status, rest = wait_for_launcher(pid, reader)
    output << rest

    expect(status).to be_success, output
    expect(output).to match(/Worker\(delayed_job\.1 .*\)\] Received SIGTERM while starting/)
    expect(output).not_to match(/Worker\(delayed_job\.0 .*\)\] Received SIGTERM while starting/)
    # delayed_job.0 ran on until the launcher was stopped.
    expect(output.index(/Child process delayed_job\.0 \(pid \d+\) exited/)).to be > output.index(/Received SIGTERM\. Waiting/)
  ensure
    reader.close if reader && !reader.closed?
    begin
      Process.kill('KILL', -pid)
    rescue StandardError
      nil
    end
  end
end
