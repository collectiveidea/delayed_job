require 'helper'
require_relative 'helpers'

# Real forking launchers sharing a pidfile: only one runs at a time.
describe 'A forking launcher with a pidfile', :processes do
  include ProcessHelpers

  let(:pid_file) { File.join(File.dirname(@process_db), 'pids', 'delayed_job.pid') }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  it 'refuses to start a second launcher while the first runs, and removes the file when it stops' do
    pid, reader = spawn_launcher(:processes => 2, :pid_file => pid_file, :worker => {:sleep_delay => 0.1})
    wait_for { File.exist?(pid_file) && File.read(pid_file) == "#{pid}\n" }

    status, output = run_launcher({:processes => 2, :pid_file => pid_file}, 20)
    expect(status).not_to be_success
    expect(output).to include "delayed_job is already running (pid #{pid}): pidfile #{pid_file} exists"
    expect(output).not_to include ') started'
    # The first launcher is unaffected.
    expect(File.read(pid_file)).to eq "#{pid}\n"
    expect(alive?(pid)).to be true

    Process.kill('TERM', pid)
    status, output = wait_for_launcher(pid, reader)
    expect(status).to be_success
    expect(output).to include "Wrote pidfile #{pid_file} - pid #{pid}"
    expect(File.exist?(pid_file)).to be false
  end

  it 'starts when a stale pidfile was left by a launcher that was SIGKILLed along with its workers' do
    pid, reader = spawn_launcher(:processes => 2, :pid_file => pid_file, :worker => {:sleep_delay => 0.1})
    wait_for { read_available(reader).include?(') started') && File.exist?(pid_file) }
    Process.kill('KILL', -pid) # The whole process group.
    Process.waitpid(pid)
    reader.close
    expect(File.read(pid_file)).to eq "#{pid}\n" # Left behind.

    job = enqueue_process_job(ProcessJobs::SleepJob.new('after restart', 0))
    status, output = run_launcher(:processes => 2, :pid_file => pid_file, :exit_on_complete => true)

    expect(status).to be_success
    expect(output).not_to include 'already running'
    expect(reload_job(job)).to be_nil
    expect(File.exist?(pid_file)).to be false
  end

  # The forked workers inherit the pidfile's lock: a new launcher can't
  # start while workers orphaned by a SIGKILLed launcher still run jobs.
  it 'refuses to start while workers of a SIGKILLed launcher still run, then starts once they exit' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('orphaned', 3))
    pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :pid_file => pid_file,
                                 :worker => {:sleep_delay => 0.1})
    owner = wait_for { reload_job(job).locked_by }
    worker = owner[/pid:(\d+)/, 1].to_i
    Process.kill('KILL', pid) # The parent only: the busy worker runs on.
    Process.waitpid(pid)

    status, output = run_launcher({:processes => 1, :pid_file => pid_file}, 20)
    expect(alive?(worker)).to be true
    expect(status).not_to be_success
    expect(output).to include "delayed_job is already running (pid #{pid})"

    # The orphaned worker finishes its job, notices its parent is gone and exits.
    wait_for(20) { !alive?(worker) }
    read_to_eof(reader, 2)
    expect(reload_job(job)).to be_nil

    status, output = run_launcher(:processes => 1, :pid_file => pid_file, :exit_on_complete => true)
    expect(status).to be_success
    expect(output).not_to include 'already running'
    expect(ProcessHelpers::Run.where(:key => 'orphaned').count).to eq 1
  end
end
