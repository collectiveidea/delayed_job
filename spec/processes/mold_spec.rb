require 'helper'
require_relative 'helpers'

# Runs a real forking launcher with Worker.mold: a child process is promoted
# to a mold, and every child process is reforked from it.
describe 'Mold process', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }
  let(:launch_options) { {:processes => 2, :mold => [5], :mold_ping_interval => 0.1, :worker => worker_settings} }

  def enqueue_sleepers(count, seconds = 0.05, attributes = {})
    Array.new(count) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("#{attributes[:queue]}job#{i}", seconds), attributes) }
  end

  # Reads output until it matches `pattern`; returns the match.
  def read_until(reader, output, pattern, timeout = 20)
    wait_for(timeout) { (output << read_available(reader)).match(pattern) }
  rescue RuntimeError
    raise "#{pattern.inspect} not seen in #{timeout}s. Output:\n#{output.lines.grep_v(/SleepJob|reserved/).join}"
  end

  def ppid_of(pid)
    `ps -o ppid= -p #{pid}`.strip.to_i
  end

  def alive?(pid)
    Delayed::ProcessUtil.alive?(pid)
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

  it 'promotes a child process to mold and reforks every child process from it' do
    enqueue_sleepers(40)
    pid, reader = spawn_launcher(launch_options.merge(:log_events => true))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    # Both slots refilled from the mold: the promoted child's, and the other's.
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 }
    children = mold_children(output, mold_pid)
    expect(children.map { |child| ppid_of(child) }).to all(eq mold_pid)
    wait_for { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/Promoting child process delayed_job\.[01] \(pid \d+\) to mold after \d+ job\(s\)/)
    expect(output).to match(/promoted to mold after \d+ job\(s\) \(threshold\)/)
    expect(output).to include "Mold (pid #{mold_pid}) activated, generation 1"
    expect(output).to match(/Reforking child process delayed_job\.[01] \(pid \d+\) from mold \(pid #{mold_pid}\)/)
    expect(output).not_to match(/waiting [\d.]+s before replacing/) # No crash back-off.
    expect(ProcessHelpers::Run.group(:key).count.values).to all(eq 1)
    expect(ProcessHelpers::Run.count).to eq 40
    expect(alive?(mold_pid)).to be false
  end

  it 'promotes again on SIGURG to the parent, stopping the retired mold, its children carrying on' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options.merge(:log_events => true))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/)
    Process.kill('URG', pid)
    second = wait_for(20) { (output << read_available(reader)).scan(/Mold \(pid (\d+)\) ready/).flatten.map(&:to_i).find { |m| m != first } }
    expect(second).not_to eq first
    wait_for { mold_children(output << read_available(reader), second).size >= 2 }
    wait_for { !alive?(first) }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/promoted to mold after \d+ job\(s\) \(signal\)/)
    expect(output).to include "Mold (pid #{first}) retired"
    expect(output).to include "Retired mold (pid #{first}) exited"
    expect(output).to include "Mold (pid #{second}) activated, generation 2"
  end

  it 'recovers and replaces a SIGKILLed child process the mold forked' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 && ProcessHelpers::Job.count.zero? }
    job = enqueue_process_job(ProcessJobs::SleepJob.new('long', 30))
    holder = wait_for { reload_job(job).locked_by.to_s[/pid:(\d+)/, 1] }.to_i
    expect(mold_children(output, mold_pid)).to include holder
    Process.kill('KILL', holder)
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 3 }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/Child process delayed_job\.\d+ \(pid #{holder}\) exited: pid #{holder} SIGKILL \(signal 9\)/)
    expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.\d+ \(pid #{holder}\)/)
    job = reload_job(job)
    expect(job.attempts).to eq 1
    expect(job.last_error).to match(/was killed by signal 9/)
  end

  it 'keeps the children of a SIGKILLed mold running, adopted by the parent, and promotes a new mold' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:mold_retry_delay_unit => 0.5, :log_events => true))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 }
    children = mold_children(output, mold_pid)
    Process.kill('KILL', mold_pid)
    read_until(reader, output, /Lost mold \(pid #{mold_pid}\); promoting a new mold in [\d.]+s/)
    expect(children).to all(satisfy { |child| alive?(child) && ppid_of(child) == pid })
    enqueue_sleepers(10, 0.05, :queue => 'later').each { |job| job.update!(:queue => nil) }
    second = wait_for(30) { (output << read_available(reader)).scan(/Mold \(pid (\d+)\) ready/).flatten.map(&:to_i).find { |m| m != mold_pid } }
    wait_for { mold_children(output << read_available(reader), second).size >= 2 }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/promoted to mold after \d+ job\(s\) \(mold_lost\)/)
    expect(output).to match(/Mold \(pid #{mold_pid}\) lost \(exited\), generation 1; promoting a new mold in [\d.]+s/)
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
    expect(ProcessHelpers::Run.group(:key).count.values).to all(eq 1)
  end

  it 'replaces the children of a SIGKILLed mold from the parent without a subreaper' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:no_subreaper => true, :mold_retry_delay_unit => 30))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 }
    orphans = mold_children(output, mold_pid)
    Process.kill('KILL', mold_pid)
    read_until(reader, output, /Mold \(pid #{mold_pid}\) exited; forking child processes from the parent/)
    wait_for { orphans.none? { |orphan| alive?(orphan) } }
    # Two started by the parent at boot, two replacing the orphans.
    wait_for { (output << read_available(reader)).scan(/\(pid \d+\) started( queues=\S+)?$/).size >= 4 }
    later = enqueue_sleepers(1).first
    wait_for { reload_job(later).nil? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to include 'could not make the parent a child subreaper'
    orphans.each do |orphan|
      expect(output).to match(/Child process delayed_job\.\d+ \(pid #{orphan}\) exited: pid #{orphan} exit unknown/)
    end
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  it 'keeps the old children when the mold forks children that crash, then stops the broken mold' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:broken_mold => true, :mold_retry_delay_unit => 30, :respawn_delay_unit => 0.1))
    output = +''
    read_until(reader, output, /Mold \(pid (\d+)\) ready/)
    read_until(reader, output, /failed to start in a row.*; stopping it/, 30)
    later = enqueue_sleepers(3, 0, :queue => 'later').each { |job| job.update!(:queue => nil) }
    wait_for { later.all? { |job| reload_job(job).nil? } } # Still working.
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/died before booting; keeping pid \d+/)
    expect(output).to match(/Mold \(pid \d+\) is broken; forking child processes from the parent/)
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  it 'promotes again when a mold dies before it is ready' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options.merge(:mold_hook_delay => 3, :mold_retry_delay_unit => 0.5))
    output = +''
    first = read_until(reader, output, /mold (\d+) hook sleeping/)[1].to_i
    Process.kill('KILL', first)
    read_until(reader, output, /Mold \(pid #{first}\) exited before it was ready; promoting a new mold in/)
    enqueue_sleepers(10, 0.05, :queue => 'more').each { |job| job.update!(:queue => nil) }
    read_until(reader, output, /Mold \(pid (?!#{first}\))\d+\) ready/, 40)
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  it 'leaks no file descriptors across generations' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    # SQLite's own files are left out: it opens its -shm file lazily, so
    # their count varies by one from child to child.
    open_fds = lambda do |child|
      Dir.children("/proc/#{child}/fd").count { |fd| !File.readlink("/proc/#{child}/fd/#{fd}").start_with?(@process_db) rescue false }
    rescue Errno::ENOENT
      nil # It exited.
    end
    # A child is logged as started when forked, while still booting with
    # fds it is about to close: take each child's fewest over a second (a
    # leaked fd stays open), then the most of any child.
    fds = lambda do |mold|
      wait_for { mold_children(output << read_available(reader), mold).size >= 2 }
      children = mold_children(output, mold)
      samples = Array.new(10) do
        sleep 0.1
        children.map { |child| open_fds.call(child) }
      end
      samples.transpose.filter_map { |counts| counts.compact.min }.max
    end
    molds = [read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i]
    counts = [fds.call(molds.last)]
    2.times do
      read_until(reader, output, /Reforked every child process from mold \(pid #{molds.last}\)/)
      Process.kill('URG', pid)
      molds << wait_for(20) { (output << read_available(reader)).scan(/Mold \(pid (\d+)\) ready/).flatten.map(&:to_i).find { |m| !molds.include?(m) } }
      counts << fds.call(molds.last)
    end
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    # Generation 1 also holds what the parent had open; none grow after.
    expect(counts.drop(1).uniq.size).to eq(1), "fd counts per generation: #{counts.inspect}"
    expect(counts.last).to be <= counts.first
    expect(output).to include 'generation 3'
  end

  it 'does not promote again on the job counts of the previous generation' do
    enqueue_sleepers(40)
    pid, reader = spawn_launcher(launch_options.merge(:mold => [5, 1000]))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { ProcessHelpers::Job.count.zero? }
    sleep 1
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output.scan(/Mold \(pid \d+\) ready/).size).to eq 1
    expect(output).to include "from mold (pid #{mold_pid})"
  end

  it 'stops the mold and its children quietly when the parent is SIGKILLed' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 }
    children = mold_children(output, mold_pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
    wait_for(20) { ([mold_pid] + children).none? { |p| alive?(p) } }
    output << read_to_eof(reader)
    reader.close

    expect(output).not_to match(/Error|failed:/)
  end

  it 'stops gracefully, molds included, when TERMed during a refork' do
    enqueue_sleepers(30, 0.3)
    pid, reader = spawn_launcher(launch_options.merge(:mold => [2]))
    output = +''
    mold_pid = read_until(reader, output, /Reforking child process .* from mold \(pid (\d+)\)/)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/delayed_job \(parent\) exited gracefully/)
    expect(alive?(mold_pid)).to be false
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
    expect(ProcessHelpers::Run.group(:key).count.values).to all(eq 1)
  end

  it 'keeps each pool on its queues across a refork' do
    enqueue_sleepers(10, 0.05, :queue => 'a')
    enqueue_sleepers(10, 0.05, :queue => 'b')
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :pools => [[['a'], 1], [['b'], 1]], :mold => [3]))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 2 }
    enqueue_sleepers(3, 0, :queue => 'a2').each { |job| job.update!(:queue => 'a') }
    enqueue_sleepers(3, 0, :queue => 'b2').each { |job| job.update!(:queue => 'b') }
    wait_for { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/started from mold \(pid #{mold_pid}\) queues=a$/)
    expect(output).to match(/started from mold \(pid #{mold_pid}\) queues=b$/)
    mold_pids = mold_children(output, mold_pid)
    expect(ProcessHelpers::Run.where(:key => %w[a2job0 a2job1 a2job2 b2job0 b2job1 b2job2]).pluck(:pid)).to all(satisfy { |p| mold_pids.include?(p) })
  end

  it 'works with a single process' do
    enqueue_sleepers(10)
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1))
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    wait_for { mold_children(output << read_available(reader), mold_pid).size >= 1 }
    wait_for { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(ProcessHelpers::Run.count).to eq 10
  end
end
