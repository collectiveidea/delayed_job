require 'helper'
require_relative 'helpers'

# Idle worker processes forked by a real forking launcher (so supervised by
# their parent) must poll the database every sleep_delay, even though they
# check on their parent every SUPERVISOR_CHECK_INTERVAL (1s).
describe 'Idle forked worker processes', :processes do
  include ProcessHelpers

  # Reservation polls in the launcher's output (logged by
  # Delayed::LogSubscriber), counted per worker process.
  def polls_per_worker(output)
    output.scan(/^delayed_job\.\d host:\S+ pid:(\d+) reserved \d+ of \d+ job\(s\)/).flatten.tally
  end

  def run_idle(seconds, worker_settings)
    pid, reader = spawn_launcher(:processes => 2, :threads => 2, :log_events => true, :worker => worker_settings)
    sleep seconds
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader)
    expect(status).to be_success, output
    output
  ensure
    reader.close if reader && !reader.closed?
  end

  it 'poll every sleep_delay, not every time they check on their parent' do
    output = run_idle(6, :sleep_delay => 3)
    polls = polls_per_worker(output)

    expect(polls.size).to eq(2), output
    # At most at 0, 3 and 6s of their (under 6s) lives, however slow the
    # machine; checking on the parent every second would mean about 6 each.
    expect(polls.values).to all(be_between(1, 3)), "polls per worker: #{polls}\n#{output}"
  end

  it 'still pick up a job enqueued while they sleep, after sleep_delay' do
    pid, reader = spawn_launcher(:processes => 1, :worker => {:sleep_delay => 1})
    sleep 2.5 # Booted, and polled to find nothing.
    job = enqueue_process_job(ProcessJobs::SleepJob.new('late', 0))
    wait_for(5) { reload_job(job).nil? }
    expect(ProcessHelpers::Run.where(:key => 'late').count).to eq 1
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader)
    expect(status).to be_success, output
  ensure
    reader.close if reader && !reader.closed?
  end
end
