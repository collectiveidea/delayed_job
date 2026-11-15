require 'helper'
require_relative 'helpers'

# Mold process cases with real forking launchers: orphans of a dead mold,
# reforks interrupted by a dying child, a mold dying with forks pending, and
# :mold hooks; then commands run by jobs, SIGURG to the whole process group,
# fork-unsafe children, and a mold signalled alone.
describe 'Mold process', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }
  let(:launch_options) { {:processes => 2, :mold => [5], :mold_ping_interval => 0.1, :worker => worker_settings} }

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

  def molds_ready(output)
    output.scan(/Mold \(pid (\d+)\) ready/).flatten.map(&:to_i).uniq
  end

  def mold_children(output, mold_pid)
    output.scan(/Child process delayed_job\.\d+ \(pid (\d+)\) started from mold \(pid #{mold_pid}\)/).flatten.map(&:to_i)
  end

  def stop_launcher(pid, reader, output)
    Process.kill('TERM', pid)
    status, rest = wait_for_launcher(pid, reader)
    output << rest
    status
  end

  # [pid, ppid, process group] of every process (Linux).
  def processes
    Dir.glob('/proc/[0-9]*/stat').map do |path|
      stat = File.read(path)
      fields = stat[(stat.rindex(')') + 2)..].split
      [path[%r{\d+}].to_i, fields[1].to_i, fields[2].to_i]
    rescue SystemCallError, IOError
      nil
    end.compact
  end

  def ppid_of(pid)
    processes.find { |process, _, _| process == pid }&.at(1)
  end

  def cmdline(pid)
    File.read("/proc/#{pid}/cmdline").tr("\0", ' ').strip
  rescue SystemCallError, IOError
    nil
  end

  # Reads output until `pattern` matches after the first `marker`.
  def read_after(reader, output, marker, pattern)
    wait_for(20) do
      output << read_available(reader)
      at = output.index(marker)
      at && output[at..].match(pattern)
    end
  rescue RuntimeError
    raise "#{pattern.inspect} not seen after #{marker.inspect} in 20s. Output:\n#{output.lines.grep_v(/SleepJob|reserved/).join}"
  end

  # Child processes the parent forked, still running and not being reforked
  # or promoted.
  def cold_children(output)
    started = output.scan(/Child process delayed_job\.\d+ \(pid (\d+)\) started$/).flatten.map(&:to_i)
    handled = output.scan(/(?:Reforking|Promoting) child process delayed_job\.\d+ \(pid (\d+)\)/).flatten.map(&:to_i)
    (started - handled).select { |child| alive?(child) }
  end

  # Bytes waiting in the pipes `pid` reads (Linux): with the mold stopped,
  # only fork requests arrive there.
  def queued_fork_bytes(pid)
    Dir.children("/proc/#{pid}/fd").sum do |fd|
      path = "/proc/#{pid}/fd/#{fd}"
      next 0 unless File.readlink(path).start_with?('pipe:')
      next 0 unless File.read("/proc/#{pid}/fdinfo/#{fd}")[/flags:\s*(\d+)/, 1].to_i(8) & 3 == File::RDONLY
      File.open(path, File::RDONLY | File::NONBLOCK) do |pipe|
        bytes = [0].pack('i')
        pipe.ioctl(0x541B, bytes) # FIONREAD
        bytes.unpack1('i')
      end
    rescue SystemCallError, IOError
      0
    end
  end

  def expect_no_locked_jobs
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  def expect_each_job_run_once(count)
    expect(ProcessHelpers::Run.group(:key).count.select { |_, runs| runs > 1 }).to be_empty
    expect(ProcessHelpers::Run.count).to eq count
  end

  # Adopted by the parent as a child subreaper, the orphan is reaped with its
  # real status.
  it 'reaps an orphan of a SIGKILLed mold with its real status, recovers its job, and replaces it from the parent' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:mold_retry_delay_unit => 60))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{mold_pid}\)/)
    wait_for { ProcessHelpers::Job.count.zero? }
    job = enqueue_process_job(ProcessJobs::SleepJob.new('long', 60))
    holder = wait_for { reload_job(job).locked_by.to_s[/pid:(\d+)/, 1] }.to_i
    expect(mold_children(output, mold_pid)).to include holder
    Process.kill('KILL', mold_pid)
    read_until(reader, output, /Lost mold \(pid #{mold_pid}\); promoting a new mold in/)
    Process.kill('KILL', holder)
    name = read_until(reader, output, /Child process (delayed_job\.\d+) \(pid #{holder}\) exited: /)[1]
    replacement = read_after(reader, output, "(pid #{holder}) exited: ", /\(pid (\d+)\) started$/)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to include "Child process #{name} (pid #{holder}) exited: pid #{holder} SIGKILL (signal 9)"
    expect(output).not_to include "(pid #{holder}) exited: pid #{holder} exit unknown"
    expect(output).to match(/Recovered 1 job\(s\) left locked by child process #{Regexp.escape(name)} \(pid #{holder}\)/)
    expect(replacement).not_to eq holder
    job = reload_job(job)
    expect(job.attempts).to eq 1
    expect(job.last_error).to match(/was killed by signal 9/)
  end

  it 'completes a refork with every child of the new generation when a new child is SIGKILLed mid-refork' do
    enqueue_sleepers(40)
    pid, reader = spawn_launcher(launch_options.merge(:processes => 4, :startup_delay => 0.5))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    victim = read_until(reader, output, /\(pid (\d+)\) started from mold \(pid #{mold_pid}\)/)[1].to_i
    expect(output).not_to include 'Reforked every child process' # Still mid-refork.
    Process.kill('KILL', victim)
    read_until(reader, output, /\(pid #{victim}\) exited: pid #{victim} SIGKILL \(signal 9\)/)
    read_until(reader, output, /Reforked every child process from mold \(pid #{mold_pid}\), generation 1/, 40)
    children = processes.select { |_, ppid, pgrp| pgrp == pid && [pid, mold_pid].include?(ppid) }.map(&:first)
    titles = children.map { |child| cmdline(child) }.compact.grep(/\Adelayed_job\.\d+/).grep_v(/: mold/)
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(titles.size).to eq(4), "child process titles: #{titles.inspect}"
    expect(titles).to all(include('gen 1'))
    expect_no_locked_jobs
  end

  it 'forks a slot from the parent when the mold dies with its replacement request pending' do
    enqueue_sleepers(40, 0.1)
    pid, reader = spawn_launcher(launch_options.merge(:processes => 4, :startup_delay => 2, :respawn_delay_unit => 0.1,
                                                      :mold_retry_delay_unit => 60))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    Process.kill('STOP', mold_pid) # Before any replacement it forks could boot: the refork is stuck.
    baseline = queued_fork_bytes(mold_pid)
    victim = cold_children(output).first
    Process.kill('KILL', victim) # A child of the parent: replaced through the stopped mold.
    read_until(reader, output, /\(pid #{victim}\) exited: pid #{victim} SIGKILL \(signal 9\)/)
    wait_for { queued_fork_bytes(mold_pid) > baseline } # Its replacement request waits in the pipe.
    Process.kill('KILL', mold_pid)
    read_until(reader, output, /Mold \(pid #{mold_pid}\) exited; forking child processes from the parent/)
    replacement = read_after(reader, output, 'forking child processes from the parent', /\(pid (\d+)\) started$/)[1].to_i
    wait_for(40) { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(replacement).not_to eq victim
    expect(output).not_to match(/did not fork a child process within/)
    expect_no_locked_jobs
    expect_each_job_run_once(40)
  end

  it 'activates a mold behind a slow before(:mold) hook, and runs the old mold\'s after(:mold) last' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options.merge(:mold_hook_delay => 3, :log_mold_hooks => true))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/)
    Process.kill('URG', pid)
    second = read_until(reader, output, /Mold \(pid (?!#{first}\))(\d+)\) ready/, 30)[1].to_i
    read_until(reader, output, /after\(:mold\) #{first} 1/)
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    hooks = output.scan(/^((?:before|after)\(:mold\)) (\d+) (\d+)$/).map { |hook, mold, gen| [hook, mold.to_i, gen.to_i] }
    expect(hooks.first(3)).to eq [['before(:mold)', first, 1], ['before(:mold)', second, 2], ['after(:mold)', first, 1]]
    expect(output.index("before(:mold) #{first} 1")).to be < output.index("Mold (pid #{first}) ready")
  end

  # The mold traps SIGCHLD; a child it forks must not inherit the trap, or
  # system() couldn't read its command's status.
  it 'lets a job in a child process the mold forked run a command and read its status' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{mold_pid}\)/)
    job = enqueue_process_job(ProcessJobs::SystemJob.new('system'))
    wait_for { reload_job(job).nil? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    run = ProcessHelpers::Run.find_by(:key => %w[system:true system:false])
    expect(run.key).to eq 'system:true'
    expect(mold_children(output, mold_pid)).to include run.pid
  end

  # The README says not to (each child takes SIGURG as its own promotion),
  # but it must not lose or repeat a job: it reaches every child process,
  # the mold and the parent at once.
  it 'runs every job once and gets a mold ready again after SIGURG to the whole process group' do
    enqueue_sleepers(30, 0.2)
    pid, reader = spawn_launcher(launch_options.merge(:mold_retry_delay_unit => 0.5))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/)
    enqueue_sleepers(20, 0.2, 'more')
    Process.kill('URG', -pid)
    second = wait_for(40) { molds_ready(output << read_available(reader)).find { |mold| mold != first } }
    wait_for(30) { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(second).not_to eq first
    expect_no_locked_jobs
    expect_each_job_run_once(50)
  end

  # The parent learns a child is fork unsafe from its pings: one promoted
  # before its next ping checks again itself.
  it 'forks no mold from a child that went fork unsafe since its last ping' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :mold_ping_interval => 60,
                                                      :mold_retry_delay_unit => 0.5))
    output = +''
    unsafe = read_until(reader, output, /Child process delayed_job\.0 \(pid (\d+)\) started/)[1].to_i
    read_until(reader, output, /delayed_job\.0.*Starting job worker/)
    enqueue_process_job(ProcessJobs::ForkUnsafeJob.new('unsafe'))
    wait_for { ProcessHelpers::Run.find_by(:key => 'unsafe') }
    Process.kill('URG', pid) # Before the next ping reports it unsafe.
    forked_by_unsafe = []
    while alive?(unsafe)
      forked_by_unsafe |= processes.select { |_, ppid, _| ppid == unsafe }.map(&:first)
      sleep 0.01
    end
    read_until(reader, output, /\(pid #{unsafe}\) exited: pid #{unsafe} exit 75/)
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(ProcessHelpers::Run.find_by(:key => 'unsafe').pid).to eq unsafe
    expect(output).to include "Child process delayed_job.0 (pid #{unsafe}) promoted to mold is no longer fork safe; not forking a mold"
    expect(forked_by_unsafe).to be_empty
    expect(ppid_of(mold_pid)).not_to eq unsafe
    promoted = output.scan(/Promoting child process delayed_job\.\d+ \(pid (\d+)\)/).flatten.map(&:to_i)
    expect(promoted.first).to eq unsafe
    expect(promoted.last).not_to eq unsafe # The mold that got ready came from its replacement.
  end
  # A mold signalled alone stops forking; it says so ("s") rather than leave
  # the parent waiting out MOLD_FORK_TIMEOUT on its next fork request.
  it 'replaces at once a mold sent TERM alone, forking from the parent meanwhile' do
    enqueue_sleepers(30, 0.05)
    pid, reader = spawn_launcher(launch_options.merge(:mold_retry_delay_unit => 0.5))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/, 40)
    Process.kill('TERM', first)
    read_until(reader, output, /Mold \(pid #{first}\) was stopped by a signal; forking child processes from the parent/, 10)
    enqueue_sleepers(30, 0.05, 'more')
    second = read_after(reader, output, 'was stopped by a signal', /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for(40) { ProcessHelpers::Job.count.zero? }
    wait_for(10) { !alive?(first) }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(second).not_to eq first
    expect(output).not_to match(/did not fork a child process within/)
    expect_no_locked_jobs
    expect_each_job_run_once(60)
  end
end
