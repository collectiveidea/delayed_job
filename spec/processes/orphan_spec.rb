require 'helper'
require_relative 'helpers'

# SIGKILLs a real forking launcher (the parent) and checks that its worker
# processes notice, finish their jobs and exit instead of running on as
# orphans.
describe 'A forking launcher that is SIGKILLed', :processes do
  include ProcessHelpers

  def worker_pids(_job)
    ProcessHelpers::Job.where.not(:locked_by => nil).pluck(:locked_by).map { |name| name[/pid:(\d+)/, 1].to_i }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  it 'leaves no orphaned worker processes behind' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('in flight', 1))
    pid, reader = spawn_launcher(:processes => 2, :worker => {:sleep_delay => 30})
    wait_for { reload_job(job).locked_by }
    busy_child = worker_pids(job).first
    output = read_available(reader)
    idle_child = (output.scan(/Child process delayed_job\.\d \(pid (\d+)\) started/).flatten.map(&:to_i) - [busy_child]).first

    Process.kill('KILL', pid)
    Process.waitpid(pid)

    # The idle worker sleeps for sleep_delay (30s) between polls, so this
    # also checks that a supervised worker checks on its parent more often.
    wait_for(10) { !alive?(busy_child) && !alive?(idle_child) }
    output << read_to_eof(reader, 2)

    expect(output.scan(/Parent process #{pid} is gone; stopping/).size).to eq 2
    # The busy worker finished its job before exiting.
    expect(ProcessHelpers::Run.where(:key => 'in flight').count).to eq 1
    expect(reload_job(job)).to be_nil
  ensure
    reader.close if reader && !reader.closed?
    [busy_child, idle_child].compact.each { |child| Process.kill('KILL', child) rescue nil }
  end
end
