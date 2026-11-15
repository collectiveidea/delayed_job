require 'helper'
require_relative 'helpers'

# The mold process crossed with per-process worker features (threads,
# prefetch, lock heartbeats, pools, shutdown_timeout, max_run_time), with
# real forking launchers. The unit level is in spec/mold_features_race_spec.rb.
describe 'Mold process with worker features', :processes do
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

  def stop_launcher(pid, reader, output, signal = 'TERM')
    Process.kill(signal, pid)
    status, rest = wait_for_launcher(pid, reader)
    output << rest
    status
  end

  def holder_pid(job)
    reload_job(job)&.locked_by.to_s[/pid:(\d+)/, 1]&.to_i
  end

  def expect_no_locked_jobs
    expect(ProcessHelpers::Job.where.not(:locked_by => nil).count).to eq 0
  end

  def expect_each_job_run_once
    expect(ProcessHelpers::Run.group(:key).count.select { |_, count| count > 1 }).to be_empty
  end

  it 'runs every job once, with no attempt counted, across two promotions with threads, dynamic prefetch and lock heartbeats' do
    enqueue_sleepers(30, 0.02)
    settings = worker_settings.merge(:prefetch => 2, :prefetch_dynamic => true, :lock_heartbeat_interval => 0.2, :lock_timeout => 2)
    pid, reader = spawn_launcher(launch_options.merge(:threads => 3, :mold => [5, 20], :worker => settings, :log_events => true))
    output = +''
    first = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{first}\)/)
    # Enough for one of the 2 reforked children to reach the next threshold (20).
    enqueue_sleepers(60, 0.02, :prefix => 'late')
    second = read_until(reader, output, /Mold \(pid (?!#{first}\))(\d+)\) ready/, 40)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{second}\)/, 40)
    wait_for(40) { ProcessHelpers::Job.count.zero? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/started from mold \(pid #{second}\) threads=3$/)
    expect(output).not_to match(/still has threads running|no longer fork safe|Recovered \d+ job|lock expired|left the job|another worker reserved it/)
    expect(ProcessHelpers::Run.count).to eq 90
    expect_each_job_run_once
    expect_no_locked_jobs
  end

  it "refills a promoted pool B child's slot from the mold with pool B's queues and threads" do
    pools = [[['a'], 1], [['b'], 1]]
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :pools => pools, :threads => 2, :worker => worker_settings.merge(:prefetch => 1)))
    output = +''
    # Keeps the pool A child busy: an idle one would be promoted instead (see the
    # pending example in spec/mold_features_race_spec.rb).
    busy = enqueue_process_job(ProcessJobs::SleepJob.new('busy', 3), :queue => 'a')
    wait_for { holder_pid(busy) }
    enqueue_sleepers(12, 0.02, :queue => 'b', :prefix => 'b')
    promoted = read_until(reader, output, /Promoting child process delayed_job\.(\d+) \(pid (\d+)\)/)
    expect(output).to match(/Child process delayed_job\.#{promoted[1]} \(pid #{promoted[2]}\) started queues=b threads=2$/)
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    read_until(reader, output, /Reforked every child process from mold \(pid #{mold_pid}\)/)
    a_jobs = enqueue_sleepers(3, 0, :queue => 'a', :prefix => 'a2')
    b_jobs = enqueue_sleepers(3, 0, :queue => 'b', :prefix => 'b2')
    wait_for { (a_jobs + b_jobs).all? { |job| reload_job(job).nil? } }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    a_child = output[/\(pid (\d+)\) started from mold \(pid #{mold_pid}\) queues=a threads=2$/, 1].to_i
    b_child = output[/\(pid (\d+)\) started from mold \(pid #{mold_pid}\) queues=b threads=2$/, 1].to_i
    expect([a_child, b_child]).to all(be > 0)
    expect(ProcessHelpers::Run.where(:key => %w[a20 a21 a22]).pluck(:pid).uniq).to eq [a_child]
    expect(ProcessHelpers::Run.where(:key => %w[b20 b21 b22]).pluck(:pid).uniq).to eq [b_child]
    expect_each_job_run_once
    expect_no_locked_jobs
  end

  it 'interrupts a draining job at the shutdown timeout without counting an attempt (count_shutdown_interrupts), then forks the mold' do
    options = launch_options.merge(:processes => 1, :mold => [1000], :shutdown_timeout => 1, :count_shutdown_interrupts => true)
    pid, reader = spawn_launcher(options)
    output = +''
    long = enqueue_process_job(ProcessJobs::SleepJob.new('long', 60))
    promoted = wait_for { holder_pid(long) }
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.\d+ \(pid #{promoted}\) to mold/)
    read_until(reader, output, /interrupted by shutdown; released for another worker/)
    mold_pid = read_until(reader, output, /Mold \(pid (\d+)\) ready/)[1].to_i
    # Taken again by the child the mold forked.
    rerun_by = wait_for { (holder = holder_pid(long)) && holder != promoted && holder }
    read_until(reader, output, /\(pid #{rerun_by}\) started from mold \(pid #{mold_pid}\)/)
    expect(output).not_to include 'counted as a failed attempt'
    expect(reload_job(long).attempts).to eq 0
    status = stop_launcher(pid, reader, output, 'QUIT')

    expect(status).to be_success
    # A real shutdown, unlike the promotion, counts it.
    expect(output.scan('interrupted by shutdown; counted as a failed attempt').size).to eq 1
    job = reload_job(long)
    expect([job.attempts, job.locked_by]).to eq [1, nil]
  end

  it 'records one failed attempt for a draining job that exceeds its max_run_time, then forks the mold' do
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000]))
    output = +''
    slow = enqueue_process_job(ProcessJobs::TimeoutJob.new('slow', 60, 2))
    promoted = wait_for { holder_pid(slow) }
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.\d+ \(pid #{promoted}\) to mold/)
    read_until(reader, output, /Mold \(pid (\d+)\) ready/)
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).not_to match(/Child process delayed_job\.\d+ \(pid #{promoted}\) exited: .*exit 75/)
    job = reload_job(slow)
    expect(job.attempts).to eq 1
    expect(job.last_error).to match(/execution expired|WorkerTimeout/)
    expect(job.run_at).to be > Time.now.utc # Rescheduled, not run again at once.
    expect(ProcessHelpers::Run.count).to eq 0
    expect_no_locked_jobs
  end

  it 'takes over the job of a promoted child SIGSTOPped while draining, which then leaves it to the new owner and forks the mold' do
    settings = worker_settings.merge(:lock_heartbeat_interval => 0.2, :lock_timeout => 1.5)
    # The slot is refilled (from the parent) after 0.5s of draining: that child takes the job over.
    pid, reader = spawn_launcher(launch_options.merge(:processes => 1, :mold => [1000], :mold_drain_deadline => 0.5, :worker => settings))
    output = +''
    long = enqueue_process_job(ProcessJobs::SleepJob.new('long', 5))
    promoted = wait_for { holder_pid(long) }
    Process.kill('URG', pid)
    read_until(reader, output, /Promoting child process delayed_job\.\d+ \(pid #{promoted}\) to mold/)
    begin
      Process.kill('STOP', promoted) # Its heartbeat stops too: the lock expires.
      taken_by = wait_for { (holder = holder_pid(long)) && holder != promoted && holder }
    ensure
      Process.kill('CONT', promoted)
    end
    read_until(reader, output, /Mold \(pid (\d+)\) ready/, 30)
    wait_for(15) { reload_job(long).nil? }
    status = stop_launcher(pid, reader, output)

    expect(status).to be_success
    expect(output).to match(/refilling its slot/)
    expect(output).to match(/pid:#{promoted}\)\] Job ProcessJobs::SleepJob \(id=#{long.id}\) was finished here, but its lock expired and another worker reserved it/)
    expect(ProcessHelpers::Run.where(:key => 'long').pluck(:pid)).to contain_exactly(promoted, taken_by) # The price of a takeover.
    expect_no_locked_jobs
  end
end
