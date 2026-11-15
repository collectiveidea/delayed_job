require 'helper'
require_relative 'helpers'

# A worker process that hangs (here: SIGSTOPped, so it doesn't exit and its
# parent can't recover its jobs) stops refreshing its locks. With lock
# heartbeats, another worker takes its job over after lock_timeout instead
# of max_run_time; when the hung worker resumes, its now-stale outcome must
# not overwrite the other worker's.
describe 'Lock heartbeats across worker processes', :processes do
  include ProcessHelpers

  let(:worker_settings) do
    {:sleep_delay => 0.1, :lock_heartbeat_interval => 0.5, :lock_timeout => 2, :max_run_time => 3600}
  end

  def pid_of(lock_name)
    lock_name[/pid:(\d+)/, 1].to_i
  end

  it "takes over a hung worker's job after lock_timeout, and the hung worker can't undo it" do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('takeover', 4), :queue => 'shared')
    pid, reader = spawn_launcher(:pools => [[['shared'], 2]], :worker => worker_settings)
    first_owner = wait_for { reload_job(job).locked_by }
    hung = pid_of(first_owner)
    # Running, not just reserved: stopped before it starts, it would never run
    # the job, only release it on resuming (its lock expired in its queue).
    early = +''
    wait_for { (early << read_available(reader)).match?(/pid:#{hung}\)\] Job .* RUNNING/) }
    Process.kill('STOP', hung)

    begin
      # The other worker reserves the job once the hung worker's lock is
      # older than lock_timeout (2s) - not max_run_time (an hour).
      second_owner = wait_for(15) { (owner = reload_job(job).locked_by) && owner != first_owner && owner }
      expect(pid_of(second_owner)).not_to eq hung
    ensure
      Process.kill('CONT', hung)
    end

    # The hung worker finishes its run of the job, but its lock was taken
    # over, so it must leave the job to the new owner, which finishes it.
    wait_for(20) { reload_job(job).nil? }
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader)
    output = early + output

    expect(status).to be_success
    expect(output).to match(/was finished here, but its lock expired and another worker reserved it/)
    expect(ProcessHelpers::Run.where(:key => 'takeover').pluck(:pid)).to contain_exactly(hung, pid_of(second_owner))
  end

  it 'keeps the lock of a long job fresh, so no other worker takes it over' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('long', 5), :queue => 'shared')
    pid, reader = spawn_launcher(:pools => [[['shared'], 2]], :worker => worker_settings)
    owner = wait_for { reload_job(job).locked_by }
    owners = []
    wait_for(20) do
      current = reload_job(job)
      owners << current.locked_by if current
      current.nil?
    end
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader)

    expect(status).to be_success
    expect(owners.compact.uniq).to eq [owner]
    expect(output).not_to include 'lock expired'
    expect(ProcessHelpers::Run.where(:key => 'long').count).to eq 1
  end
end
