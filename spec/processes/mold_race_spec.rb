require 'helper'
require_relative 'helpers'

# Races of the mold process with real forking launchers: signals arriving in
# each phase of a promotion or refork, and jobs across a promotion. The unit
# level is in spec/mold_race_spec.rb.
describe 'Mold process races', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }
  let(:launch_options) { {:processes => 2, :mold => [5], :mold_ping_interval => 0.1, :worker => worker_settings} }

  def enqueue_sleepers(count, seconds = 0.05, attributes = {})
    prefix = attributes.delete(:prefix) || 'job'
    Array.new(count) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("#{prefix}#{i}", seconds), attributes) }
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

  def stop_launcher(pid, reader, output, signal = 'TERM')
    Process.kill(signal, pid)
    status, rest = wait_for_launcher(pid, reader)
    output << rest
    status
  end

  def expect_no_locked_jobs
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  def expect_each_job_run_once
    expect(ProcessHelpers::Run.group(:key).count.select { |_, count| count > 1 }).to be_empty
  end

  it 'stops gracefully when TERMed the moment a mold becomes ready' do
    enqueue_sleepers(30)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/delayed_job \(parent\) exited gracefully/)
    expect(alive?(mold_pid)).to be false
    expect_no_locked_jobs
    expect_each_job_run_once
  end

  it 'stops gracefully when TERMed between the mold forking and becoming ready' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options.merge(:mold_hook_delay => 2))
    output = +''
    mold_pid = read_until(reader, output, /mold (\d+) hook sleeping/)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).not_to match(/Mold \(pid #{mold_pid}\) ready; reforking/)
    expect(alive?(mold_pid)).to be false
    expect_no_locked_jobs
    expect_each_job_run_once
  end

  it 'promotes once for a burst of SIGURG' do
    enqueue_sleepers(20)
    pid, reader = spawn_launcher(launch_options)
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/)
    5.times { Process.kill('URG', pid) }
    second = read_until(reader, output, /Mold \(pid (?!#{first}\))(\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{second}\)/)
    2.times { Process.kill('URG', pid) } # The second one while promoting or reforking.
    third = read_until(reader, output, /Mold \(pid (?!(?:#{first}|#{second})\))(\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{third}\)/)
    sleep 0.5 # Any extra promotion would start within a few ticks.
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output.scan(/to mold after \d+ job\(s\) \(signal\)/).size).to eq 2
    expect(molds_ready(output).size).to eq 3
    expect(output).to include 'generation 3'
    expect(output).not_to include 'generation 4'
  end

  it 'replaces a promoted child SIGKILLed while draining, recovers its job, and promotes again' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :mold_retry_delay_unit => 0.5))
    output = +''
    long = enqueue_process_job(ProcessJobs::SleepJob.new('long', 30))
    holder = wait_for { reload_job(long)&.locked_by.to_s[/pid:(\d+)/, 1] }.to_i
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.\d+ \(pid #{holder}\) to mold after 0 job\(s\) \(signal\)/)
    Process.kill('KILL', holder)
    read_until(reader, output, /\(pid #{holder}\) promoted to mold exited with pid #{holder} SIGKILL \(signal 9\), forking no mold; promoting a new mold in/)
    # Retried as a signal promotion, once a replacement has booted.
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)[1].to_i
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.\d+ \(pid #{holder}\)/)
    expect(output.scan(/to mold after \d+ job\(s\) \(signal\)/).size).to eq 2
    expect(alive?(mold_pid)).to be false
    job = reload_job(long)
    expect(job.attempts).to eq 1
    expect(job.last_error).to match(/was killed by signal 9/)
    expect_no_locked_jobs
  end

  it 'keeps the old child and stops the replacement when the mold is SIGKILLed mid refork step' do
    enqueue_sleepers(30)
    pid, reader = spawn_launcher(launch_options.merge(:startup_delay => 2, :mold_retry_delay_unit => 30))
    output = +''
    match = read_until(reader, output, /Reforking child process delayed_job\.\d+ \(pid (\d+)\) from mold \(pid (\d+)\)/, 30)
    old = match[1].to_i
    mold_pid = match[2].to_i
    Process.kill('KILL', mold_pid)
    read_until(reader, output, /Lost mold \(pid #{mold_pid}\); promoting a new mold in/)
    expect(alive?(old)).to be true
    later = enqueue_sleepers(5, 0, :prefix => 'later')
    wait_for(30) { later.all? { |job| reload_job(job).nil? } } # Still working.
    expect(alive?(old)).to be true
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).not_to match(/Child process delayed_job\.\d+ \(pid #{old}\) exited: .*SIGKILL/)
    expect_no_locked_jobs
    expect_each_job_run_once
  end

  it 'stops, molds included, when QUIT during a refork' do
    enqueue_sleepers(30, 0.3)
    pid, reader = spawn_launcher(launch_options.merge(:mold => [2]))
    output = +''
    mold_pid = read_until(reader, output, /Reforking child process .* from mold \(pid (\d+)\)/)[1].to_i
    status = stop_launcher(pid, reader, output, 'QUIT')

    expect(status).to be_success
    expect(output).to match(/delayed_job \(parent\) exited gracefully/)
    expect(alive?(mold_pid)).to be false
    expect_no_locked_jobs
    expect_each_job_run_once
    expect(ProcessHelpers::Job.where('attempts > 0').count).to eq 0 # Interrupted jobs don't count an attempt.
  end

  it 'never promotes with exit_on_complete' do
    enqueue_sleepers(20, 0.01)
    status, output = run_launcher(launch_options.merge(:mold => [2], :exit_on_complete => true), 60)

    expect(status).to be_success
    expect(output).not_to include 'Promoting child process'
    expect(output).not_to match(/Mold \(pid \d+\)/)
    expect(ProcessHelpers::Run.count).to eq 20
    expect_each_job_run_once
  end

  it 'loses no queued job across promotions with prefetch' do
    enqueue_sleepers(80, 0.02)
    settings = worker_settings.merge(:prefetch => 3)
    pid, reader = spawn_launcher(launch_options.merge(:threads => 2, :mold => [5, 15], :worker => settings, :log_events => true))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Mold \(pid (?!#{first}\))\d+\) ready/, 40)
    wait_for(40) { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/queued job\(s\) on promotion to mold/)
    expect(ProcessHelpers::Run.count).to eq 80
    expect_each_job_run_once
    expect_no_locked_jobs
  end
end
