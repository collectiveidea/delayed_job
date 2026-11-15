require 'helper'
require_relative 'helpers'

# Stops a real forking launcher with signals sent to the parent process only,
# as `docker stop`, Kubernetes and systemd (KillMode=process) do.
describe 'Stopping a forking launcher', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1} }

  def elapsed
    started = Time.now
    result = yield
    [Time.now - started, result]
  end

  it 'forwards TERM to the worker processes, which finish their jobs and exit' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('finishes', 1))
    pid, reader = spawn_launcher(:processes => 2, :worker => worker_settings)
    wait_for { reload_job(job).locked_by }
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader, 20)

    expect(status).to be_success
    expect(output).to include 'Received SIGTERM'
    expect(output).to match(/Child process delayed_job\.0 \(pid \d+\) exited: pid \d+ exit 0/)
    expect(output).to match(/Child process delayed_job\.1 \(pid \d+\) exited: pid \d+ exit 0/)
    expect(ProcessHelpers::Run.where(:key => 'finishes').count).to eq 1
    expect(reload_job(job)).to be_nil
  end

  it 'interrupts and releases jobs still running after the shutdown timeout' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('too slow', 60))
    pid, reader = spawn_launcher(:processes => 2, :shutdown_timeout => 1, :worker => worker_settings)
    wait_for { reload_job(job).locked_by }
    Process.kill('TERM', pid)
    took, (status, output) = elapsed { wait_for_launcher(pid, reader, 30) }

    expect(status).to be_success
    expect(took).to be < 10
    expect(output).to include 'Shutdown timeout of 1s exceeded: interrupting 1 running job(s)'
    expect(output).to include 'interrupted by shutdown; released for another worker'
    expect(output).not_to include 'Kill invoked'
    job = reload_job(job)
    expect(job.locked_by).to be_nil
    expect(job.attempts).to eq 0
    expect(ProcessHelpers::Run.where(:key => 'too slow').count).to eq 0
  end

  # A child that can't exit (frozen); one whose job merely ignores the
  # interrupt exits JOBS_STUCK by itself, before the kill.
  it 'kills a frozen child, recovers its job, and exits with status 1 after the recovery' do
    job = enqueue_process_job(ProcessJobs::FreezeJob.new('frozen'))
    pid, reader = spawn_launcher(:processes => 2, :shutdown_timeout => 1, :worker => worker_settings)
    wait_for { reload_job(job).locked_by }
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader, 40)

    expect(status.exitstatus).to eq 1
    expect(output).to match(/exited forcefully after \d+ second timeout/)
    expect(output).not_to include 'exited gracefully'
    expect(output).not_to include 'No child processes found'
    job = reload_job(job)
    expect(job.locked_by).to be_nil
    expect(job.attempts).to eq 1
  end

  it 'lets a child whose job ignores the interrupt exit JOBS_STUCK before the kill, recovering its job' do
    job = enqueue_process_job(ProcessJobs::StubbornJob.new('stubborn'))
    pid, reader = spawn_launcher(:processes => 2, :shutdown_timeout => 1, :worker => worker_settings)
    wait_for { reload_job(job).locked_by }
    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader, 40)

    expect(status).to be_success
    expect(output).not_to include 'Kill invoked'
    expect(output).to match(/exited: pid \d+ exit #{Delayed::Launcher::Forking::JOBS_STUCK}$/)
    job = reload_job(job)
    expect(job.locked_by).to be_nil
    expect(job.attempts).to eq 1
  end

  it 'interrupts and releases running jobs at once on QUIT' do
    skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
    job = enqueue_process_job(ProcessJobs::SleepJob.new('quit', 60))
    pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :worker => worker_settings)
    wait_for { reload_job(job).locked_by }
    Process.kill('QUIT', pid)
    took, (status, output) = elapsed { wait_for_launcher(pid, reader, 30) }

    expect(status).to be_success
    expect(took).to be < 5
    expect(output).to include 'Received SIGQUIT'
    expect(output).to include 'Quitting: interrupting 1 running job(s)'
    expect(reload_job(job).locked_by).to be_nil
    expect(reload_job(job).attempts).to eq 0
  end
end

describe 'Signalling a forking launcher while a worker process starts up', :processes do
  include ProcessHelpers

  it 'stops the starting worker instead of losing the signal' do
    pid, reader = spawn_launcher(:processes => 2, :startup_delay => 2, :worker => {:sleep_delay => 0.1})
    output = +''
    wait_for do
      output << read_available(reader)
      output.scan(/worker \d+ starting up/).size == 2
    end
    # Both workers are inside after_fork, before installing their own traps.
    Process.kill('TERM', -pid)
    status, rest = wait_for_launcher(pid, reader, 20)
    output << rest

    expect(status).to be_success
    expect(output.scan(/Received SIGTERM while starting/).size).to eq 2
    expect(output).to match(/Child process delayed_job\.0 \(pid \d+\) exited: pid \d+ exit 0/)
    expect(output).to match(/Child process delayed_job\.1 \(pid \d+\) exited: pid \d+ exit 0/)
    # Only the parent logs and forwards; the workers no longer run its trap.
    expect(output.scan(/Received SIGTERM\. Waiting for workers/).size).to eq 1
  end
end
