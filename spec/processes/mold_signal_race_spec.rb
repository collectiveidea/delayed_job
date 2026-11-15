require 'helper'
require_relative 'helpers'

# The mold process lifecycle crossed with signals and process death, with
# real forking launchers: stop signals to the parent or the whole process
# group in each phase of a promotion or refork, the shutdown timeout's kill
# while molds and their children exist, and the parent dying mid-promotion.
# Other races are in spec/processes/mold_race_spec.rb; the unit level is in
# spec/mold_signal_race_spec.rb.
describe 'Mold process signal races', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }
  let(:launch_options) { {:processes => 2, :mold => [5], :mold_ping_interval => 0.1, :worker => worker_settings} }
  let(:pid_file) { File.join(File.dirname(@process_db), 'pids', 'delayed_job.pid') }

  def enqueue_sleepers(count, seconds = 0.05, prefix = 'job')
    Array.new(count) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("#{prefix}#{i}", seconds)) }
  end

  # Reads output until it matches `pattern`; returns the match.
  def read_until(reader, output, pattern, timeout = 20)
    wait_for(timeout) { (output << read_available(reader)).match(pattern) }
  rescue RuntimeError
    raise "#{pattern.inspect} not seen in #{timeout}s. Output:\n#{output.lines.grep_v(/SleepJob|reserved/).join}"
  end

  def alive?(pid)
    Delayed::ProcessUtil.alive?(pid)
  end

  # Pids of the live (not zombie) processes in process group `pgid` (Linux):
  # the launcher, its children, molds and their children all stay in it.
  def group_members(pgid)
    Dir.glob('/proc/[0-9]*/stat').map do |path|
      stat = File.read(path)
      state, _ppid, pgrp = stat[(stat.rindex(')') + 2)..].split
      path[/\d+/].to_i if pgrp.to_i == pgid && state != 'Z'
    rescue SystemCallError, IOError
      nil
    end.compact
  end

  def expect_no_process_left(pgid, timeout = 10)
    wait_for(timeout) { group_members(pgid).empty? }
  rescue RuntimeError
    raise "processes of group #{pgid} still running: #{group_members(pgid).map { |p| File.read("/proc/#{p}/cmdline").tr("\0", ' ') rescue p }}"
  end

  # The pidfile's flock is held by every descendant (they inherit it).
  def pidfile_unlocked?
    File.open(pid_file, File::RDWR) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
  rescue Errno::ENOENT
    true
  end

  def stop_launcher(pid, reader, output, signal = 'TERM')
    Process.kill(signal, pid)
    status, rest = wait_for_launcher(pid, reader, 40)
    output << rest
    status
  end

  def elapsed
    started = Time.now
    result = yield
    [Time.now - started, result]
  end

  def expect_no_locked_jobs
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  def expect_each_job_run_once
    expect(ProcessHelpers::Run.group(:key).count.select { |_, runs| runs > 1 }).to be_empty
  end

  def holder_of(job)
    wait_for { reload_job(job)&.locked_by.to_s[/pid:(\d+)/, 1] }.to_i
  end

  # Ctrl-C in a terminal: every process, the mold mid-hook included, gets INT.
  it 'stops gracefully on INT to the whole process group while the mold runs its before(:mold) hook' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options.merge(:mold_hook_delay => 2))
    output = +''
    mold_pid = read_until(reader, output, /mold (\d+) hook sleeping/)[1].to_i
    Process.kill('INT', -pid)
    status, rest = wait_for_launcher(pid, reader, 30)
    output << rest

    expect(status).to be_success
    expect(output).not_to match(/Mold \(pid #{mold_pid}\) ready; reforking/)
    expect(output).not_to match(/Mold \(pid \d+\) failed/)
    expect_no_process_left(pid)
    expect_no_locked_jobs
    expect_each_job_run_once
  end

  # The replacement is forked by the mold but still in after_fork: it gets
  # the TERM directly, before its own traps exist.
  it 'stops gracefully on TERM to the whole process group mid refork step, the replacement not yet booted' do
    enqueue_sleepers(30, 0.1)
    pid, reader = spawn_launcher(launch_options.merge(:startup_delay => 1.5, :mold_retry_delay_unit => 30))
    output = +''
    match = read_until(reader, output, /Child process delayed_job\.\d+ \(pid (\d+)\) started from mold \(pid (\d+)\)/, 30)
    replacement = match[1].to_i
    read_until(reader, output, /worker #{replacement} starting up/)
    Process.kill('TERM', -pid)
    status, rest = wait_for_launcher(pid, reader, 30)
    output << rest

    expect(status).to be_success
    expect(output).to match(/\(pid #{replacement}\) exited: pid #{replacement} exit 0/)
    expect(output).not_to match(/SIGKILL/)
    expect_no_process_left(pid)
    expect_no_locked_jobs
    expect_each_job_run_once
    expect(ProcessHelpers::Job.where('attempts > 0').count).to eq 0
  end

  # HUP is forwarded as TERM, which overrides the promotion: the draining
  # child finishes its job and exits 75 rather than fork a mold.
  it 'cancels the promotion of the only child, draining a job, on HUP: it finishes the job and forks no mold' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000]))
    output = +''
    job = enqueue_process_job(ProcessJobs::SleepJob.new('draining', 2))
    holder = holder_of(job)
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.0 \(pid #{holder}\) to mold/)
    status = stop_launcher(pid, reader, output, 'HUP')

    expect(status).to be_success
    expect(output).to include "(pid #{holder}) exited: pid #{holder} exit 75"
    expect(output).not_to match(/Mold \(pid \d+\)/)
    expect(output).not_to include 'Kill invoked'
    expect(ProcessHelpers::Run.where(:key => 'draining').count).to eq 1
    expect(reload_job(job)).to be_nil
    expect_no_process_left(pid)
  end

  # -n 1: no capacity while the only child drains as promoted. The shutdown
  # timeout interrupts its job, released without an attempt.
  it 'releases the job of the only child, promoted and draining, at the shutdown timeout without an attempt' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :shutdown_timeout => 1))
    output = +''
    job = enqueue_process_job(ProcessJobs::SleepJob.new('too slow', 60))
    holder = holder_of(job)
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.0 \(pid #{holder}\) to mold/)
    took, status = elapsed { stop_launcher(pid, reader, output) }

    expect(status).to be_success
    expect(took).to be < 10
    expect(output).to include "(pid #{holder}) exited: pid #{holder} exit 75"
    expect(output).not_to include 'Kill invoked'
    job = reload_job(job)
    expect(job.locked_by).to be_nil
    expect(job.attempts).to eq 0
    expect_no_process_left(pid)
  end

  # A stuck job (ignoring its interrupt) is cut off mid-run when the
  # promoted child exits: JOBS_STUCK, not a clean give-up (75), so the job
  # counts an attempt, as SIGKILL would. Otherwise a job ignoring interrupts
  # would run, and be cut off, forever.
  it 'counts an attempt for a job a promoted child abandons, stuck past the shutdown timeout' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :shutdown_timeout => 1,
                                                      :mold_retry_delay_unit => 60))
    output = +''
    job = enqueue_process_job(ProcessJobs::StubbornJob.new('stubborn'))
    holder = holder_of(job)
    Process.kill('URG', pid)
    read_until(reader, output, /\(pid #{holder}\) exiting with job thread\(s\) still running/, 15)
    read_until(reader, output, /\(pid #{holder}\) exited: pid #{holder} exit #{Delayed::Launcher::Forking::JOBS_STUCK}/)
    attempts = wait_for { reload_job(job).attempts.nonzero? } # Recovered right after the exit is logged.
    Process.kill('KILL', -pid)
    wait_for_launcher(pid, reader)

    expect(attempts).to eq 1
  end

  # The same without a stop or promotion: a refork step stops the child
  # once its replacement boots, and no kill follows. The child exits
  # JOBS_STUCK, not 0, so the parent counts an attempt.
  it 'counts an attempt for a job a reforked child abandons, stuck past the shutdown timeout' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:shutdown_timeout => 1))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/, 30)
    wait_for { ProcessHelpers::Job.count.zero? }
    job = enqueue_process_job(ProcessJobs::StubbornJob.new('stubborn'))
    holder = holder_of(job)
    Process.kill('URG', pid) # Promotes the idle child, then reforks the busy one.
    read_until(reader, output, /\(pid #{holder}\) exited: pid #{holder} exit #{Delayed::Launcher::Forking::JOBS_STUCK}/, 30)
    attempts = wait_for { reload_job(job).attempts.nonzero? }
    Process.kill('KILL', -pid)
    wait_for_launcher(pid, reader)

    expect(output).to match(/pid:#{holder}\)\] 1 job\(s\) did not stop within 5s of being interrupted/)
    expect(attempts).to eq 1
  end

  # Shutdown with molds and a stuck child (gen 1) holding a job no
  # interrupt stops: it exits JOBS_STUCK by itself, INTERRUPT_GRACE after
  # the shutdown timeout, before the parent's kill would fire. The retired
  # mold (still waiting for it without a subreaper) then exits; the job is
  # recovered once, with an attempt, and the parent exits cleanly.
  [false, true].each do |no_subreaper|
    it "stops molds and children at the shutdown timeout with a stuck child of a retired mold (#{no_subreaper ? 'no ' : ''}subreaper)" do
      enqueue_sleepers(10)
      pid, reader = spawn_launcher(launch_options.merge(:no_subreaper => no_subreaper, :shutdown_timeout => 1))
      output = +''
      first = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
      read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/, 30)
      wait_for { ProcessHelpers::Job.count.zero? }
      job = enqueue_process_job(ProcessJobs::UnkillableJob.new('unkillable'))
      holder = holder_of(job)
      Process.kill('URG', pid) # Promotes the idle child; the busy one is reforked last.
      second = read_until(reader, output, /Mold \(pid (?!#{first}\))(\d+)\) ready/, 30)[1].to_i
      read_until(reader, output, /Reforking child process delayed_job\.\d+ \(pid #{holder}\) from mold \(pid #{second}\)/, 30)
      wait_for { alive?(first) == no_subreaper } # Without a subreaper, retired, it waits for the stuck child.
      status = stop_launcher(pid, reader, output)

      expect(status).to be_success
      expect(output).not_to include 'Kill invoked'
      expect(output.scan(/\(pid #{holder}\) exited: /).size).to eq 1
      expect(output).to match(/\(pid #{holder}\) exited: pid #{holder} exit #{Delayed::Launcher::Forking::JOBS_STUCK}$/)
      job = reload_job(job)
      expect(job.locked_by).to be_nil
      expect(job.attempts).to eq 1
      expect(alive?(second)).to be false
      expect_no_process_left(pid)
    end

    # The active mold dies while the parent stops and one of its children
    # drains a job: no replacement is forked and no mold promoted, and the
    # child (adopted, or orphaned without a subreaper) finishes its job.
    it "finishes a draining job, forking nothing, when the mold is SIGKILLed during shutdown (#{no_subreaper ? 'no ' : ''}subreaper)" do
      enqueue_sleepers(10)
      pid, reader = spawn_launcher(launch_options.merge(:no_subreaper => no_subreaper, :mold_retry_delay_unit => 0.1))
      output = +''
      mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
      read_until(reader, output, /Reforked every child process from mold \(pid #{mold_pid}\)/, 30)
      wait_for { ProcessHelpers::Job.count.zero? }
      job = enqueue_process_job(ProcessJobs::SleepJob.new('draining', 3))
      holder = holder_of(job)
      Process.kill('TERM', pid)
      read_until(reader, output, /Received SIGTERM/)
      Process.kill('KILL', mold_pid)
      status, rest = wait_for_launcher(pid, reader, 30)
      output << rest

      expect(status).to be_success
      after_stop = output[output.index('Received SIGTERM')..]
      expect(after_stop).not_to match(/\) started|Promoting child process|promoting a new mold|forking child processes from the parent/)
      expect(after_stop).to match(/\(pid #{holder}\) exited: pid #{holder} (exit 0#{'|exit unknown' if no_subreaper})$/)
      expect(ProcessHelpers::Run.where(:key => 'draining').count).to eq 1
      expect(reload_job(job)).to be_nil
      expect_no_process_left(pid)
    end
  end

  # -n 1: with the promoted child gone and its mold not yet ready, no child
  # process is left; TERM must neither refill the slot nor wait out
  # MOLD_STOP_TIMEOUT once the mold finishes its hook.
  it 'stops gracefully with no child process left, the only slot deferred to a mold still in its hook' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold_hook_delay => 2))
    output = +''
    mold_pid = read_until(reader, output, /mold (\d+) hook sleeping/)[1].to_i
    read_until(reader, output, /Child process delayed_job\.0 \(pid \d+\) exited: pid \d+ exit 0/)
    took, status = elapsed { stop_launcher(pid, reader, output) }

    expect(status).to be_success
    expect(took).to be < Delayed::Launcher::MoldSupervisor::MOLD_STOP_TIMEOUT
    expect(output[output.index('Received SIGTERM')..]).not_to match(/\) started/)
    expect(output).not_to match(/Mold \(pid #{mold_pid}\) ready; reforking/)
    expect(output).not_to include 'Killing mold(s)'
    expect_no_process_left(pid)
    expect_no_locked_jobs
  end

  # Molds whose children all crash are lost one after another until
  # promotion is disabled; the children left are cold (or of no
  # generation), and with no mold nothing reforks them. SIGURG must re-arm.
  it 're-arms promotion on SIGURG once lost molds disabled it' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:broken_mold => true, :mold_retry_delay_unit => 0.05, :respawn_delay_unit => 0.05))
    output = +''
    read_until(reader, output, /mold promotions failed in a row, so no more are tried/, 40)
    Process.kill('URG', pid)
    read_until(reader, output, /Received SIGURG(: promoting to mold again| while a promotion or refork is in progress)/)
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to include 'Received SIGURG: promoting to mold again'
  end

  # The promoted child's poll loop is over while it drains, so nothing
  # checks the parent any more: once its job is done it forks a mold for no
  # one, which runs the before(:mold) hooks until its watchdog sees the life
  # pipe closed.
  it 'forks no mold from a promoted child draining a job when the parent is SIGKILLed, and releases the pidfile' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :pid_file => pid_file))
    output = +''
    job = enqueue_process_job(ProcessJobs::SleepJob.new('draining', 2))
    holder = holder_of(job)
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.0 \(pid #{holder}\) to mold/)
    Process.kill('KILL', pid)
    Process.wait(pid)
    expect_no_process_left(pid)
    output << read_to_eof(reader, 2)
    reader.close

    expect(pidfile_unlocked?).to be_truthy
    expect(ProcessHelpers::Run.where(:key => 'draining').count).to eq 1
    expect(output).not_to match(/Mold \(pid \d+\): the parent is gone/)
  end

  # The mold exits at once, mid-hook, when the parent dies.
  it 'leaves no process and releases the pidfile when the parent is SIGKILLed while the mold runs its hook' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:mold_hook_delay => 60, :pid_file => pid_file))
    output = +''
    mold_pid = read_until(reader, output, /mold (\d+) hook sleeping/)[1].to_i
    Process.kill('KILL', pid)
    Process.wait(pid)
    expect_no_process_left(pid)
    output << read_to_eof(reader, 2)
    reader.close

    expect(pidfile_unlocked?).to be_truthy
    expect(output).to include "Mold (pid #{mold_pid}): the parent is gone; exiting"
    expect_no_locked_jobs
  end

  # Without a subreaper the retired mold is the stuck child's parent: both
  # notice the launcher is gone (the life pipe; the child through its mold).
  it 'leaves no process when the parent is SIGKILLed with a retired mold waiting for its busy child (no subreaper)' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:no_subreaper => true, :pid_file => pid_file))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/, 30)
    wait_for { ProcessHelpers::Job.count.zero? }
    job = enqueue_process_job(ProcessJobs::SleepJob.new('busy', 3))
    holder = holder_of(job)
    Process.kill('URG', pid)
    read_until(reader, output, /Retired mold \(pid #{first}\); it exits once its child processes have/, 30)
    expect(alive?(holder)).to be true
    Process.kill('KILL', pid)
    Process.wait(pid)
    expect_no_process_left(pid)
    output << read_to_eof(reader, 2)
    reader.close

    expect(pidfile_unlocked?).to be_truthy
    expect(ProcessHelpers::Run.where(:key => 'busy').count).to eq 1
    expect(reload_job(job)).to be_nil
  end

  # Mid refork step, the replacement forked by the mold still starting up:
  # the mold exits on the life pipe's EOF, and every child (the replacement
  # once it starts polling) stops on its parent changing.
  [false, true].each do |no_subreaper|
    it "leaves no process when the parent is SIGKILLed mid refork step, the replacement starting up (#{no_subreaper ? 'no ' : ''}subreaper)" do
      enqueue_sleepers(20)
      pid, reader = spawn_launcher(launch_options.merge(:no_subreaper => no_subreaper, :startup_delay => 1.5, :pid_file => pid_file))
      output = +''
      match = read_until(reader, output, /Child process delayed_job\.\d+ \(pid (\d+)\) started from mold \(pid (\d+)\)/, 30)
      replacement = match[1].to_i
      read_until(reader, output, /worker #{replacement} starting up/)
      Process.kill('KILL', pid)
      Process.wait(pid)
      expect_no_process_left(pid, 15)
      output << read_to_eof(reader, 2)
      reader.close

      expect(pidfile_unlocked?).to be_truthy
      expect(output).to match(/Worker\(delayed_job\.\d+ host:\S+ pid:#{replacement}\)\] Parent process \d+ is gone; stopping/)
      expect_no_locked_jobs
    end
  end
end
