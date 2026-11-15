require 'helper'
require_relative 'helpers'

# Runs a real forking launcher whose worker processes die mid-job, and checks
# that their jobs are recovered right away instead of staying locked until
# max_run_time.
describe 'A worker process dying while running jobs', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }

  # A dead worker process (SIGKILLed, or crashed with a failure status) is
  # replaced, and its job recovered at once; the others carry on.
  context 'when it is SIGKILLed' do
    it 'recovers its job and replaces the worker, leaving the others running' do
      job = enqueue_process_job(ProcessJobs::KillJob.new('killed', 'KILL'))
      pid, reader = spawn_launcher(:processes => 2, :worker => worker_settings)
      wait_for { reload_job(job).attempts == 1 }
      output = +''
      wait_for { (output << read_available(reader)) =~ /Child process delayed_job\.2 \(pid \d+\) started/ }
      later = enqueue_process_job(ProcessJobs::SleepJob.new('after the kill', 0))
      wait_for { reload_job(later).nil? } # The launcher still works jobs.
      Process.kill('TERM', -pid)
      status, rest = wait_for_launcher(pid, reader)
      output << rest

      expect(status).to be_success
      expect(output).to match(/Child process delayed_job\.\d \(pid \d+\) was SIGKILLed \(e\.g\. by the OOM killer\); replacing it/)
      expect(output).not_to match(/SIGKILL detected/)
      expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.\d \(pid \d+\)/)
      job = reload_job(job)
      expect([job.locked_by, job.attempts]).to eq [nil, 1]
      expect(job.last_error).to match(/\AChild process delayed_job\.\d \(pid \d+\) was killed by signal 9/)
      expect(ProcessHelpers::Run.where(:key => 'after the kill').count).to eq 1
    end
  end

  context 'when it exits with a failure status' do
    it 'recovers its job and replaces the worker' do
      job = enqueue_process_job(ProcessJobs::ExitJob.new('exit', 3))
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :worker => worker_settings)
      wait_for { reload_job(job).attempts == 1 }
      # The replacement comes after a 1s back-off (it died at once).
      output = +''
      wait_for { (output << read_available(reader)) =~ /Child process delayed_job\.1 \(pid \d+\) started/ }
      Process.kill('TERM', -pid) # the process group, as a terminal or init system does
      status, rest = wait_for_launcher(pid, reader)
      output << rest

      expect(status).to be_success
      expect(output).to match(/Child process delayed_job\.0 \(pid \d+\) exited: pid \d+ exit 3/)
      expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.0 \(pid \d+\)/)
      expect(output).to match(/Child process delayed_job\.1 \(pid \d+\) started/)
      job = reload_job(job)
      expect(job.attempts).to eq 1
      expect(job.last_error).to match(/\AChild process delayed_job\.0 \(pid \d+\) exited with status 3/)
      expect(job.locked_by).to be_nil
      expect(job.run_at).to be > job.created_at
    end

    it 'publishes events for the recovery and the replacement' do
      job = enqueue_process_job(ProcessJobs::ExitJob.new('exit', 3))
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :worker => worker_settings, :log_events => true)
      output = +''
      wait_for do
        output << read_available(reader)
        output =~ /Child process delayed_job\.1 \(pid \d+\) spawned replacing pid/ && reload_job(job).attempts == 1
      end
      sleep 0.5 # let the replacement worker start
      Process.kill('TERM', -pid)
      status, rest = wait_for_launcher(pid, reader)
      output << rest

      expect(status).to be_success
      dead = output[/Child process delayed_job\.0 \(pid (\d+)\) started/, 1]
      new_pid = output[/Child process delayed_job\.1 \(pid (\d+)\) started/, 1]
      # It died at once, so it is replaced after the first back-off delay.
      expect(output).to match(/Child process delayed_job\.0 \(pid #{dead}\) exited after [\d.]+s: pid #{dead} exit 3; replacing it in 1s/)
      expect(output).to include "Child process delayed_job.1 (pid #{new_pid}) spawned replacing pid #{dead}"
      expect(output).to match(/Released 1 job\(s\) of delayed_job\.0 host:\S+ pid:#{dead} \(process exit\)/)
      expect(output).to match(/Job ProcessJobs::ExitJob \(id=#{job.id}\) failed attempt 1 on delayed_job\.0 .* with Delayed::ProcessExitError/)
      expect(output).to match(/Started delayed_job\.1 host:\S+ pid:#{new_pid} \(pid #{new_pid}, 1 thread\(s\), queues=\*\)/)
      expect(output).to match(/Stopped delayed_job\.1 host:\S+ pid:#{new_pid} \(pid #{new_pid}\)/)
    end

    it 'fails the job permanently once it has used all its attempts' do
      job = enqueue_process_job(ProcessJobs::ExitJob.new('exit', 3), :attempts => 1)
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]],
                                   :worker => worker_settings.merge(:max_attempts => 2, :destroy_failed_jobs => false))
      # The lock is cleared just after failed_at is saved; the parent then
      # forks a replacement worker. Stop once it has started, so the TERM
      # isn't racing the fork (that case is covered in shutdown_spec.rb).
      output = +''
      wait_for do
        output << read_available(reader)
        output =~ /Child process delayed_job\.1 \(pid \d+\) started/ && (j = reload_job(job)).failed_at && j.locked_by.nil?
      end
      Process.kill('TERM', -pid) # the process group, as a terminal or init system does
      status, rest = wait_for_launcher(pid, reader)
      output << rest

      expect(status).to be_success

      expect(output).to include 'Recovered 1 job(s)'
      job = reload_job(job)
      expect(job.attempts).to eq 2
      expect(job.failed_at).not_to be_nil
      expect(job.locked_by).to be_nil
    end
  end

  context 'when it keeps dying as it starts up' do
    # Respawn delays of 0.25s, 0.5s, 1s, 2s... rather than 1s, 2s, 4s, 8s.
    let(:unit) { 0.25 }

    it 'is replaced after a growing delay, until one starts' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :crash_on_start => 3, :respawn_delay_unit => unit, :worker => worker_settings)
      output = +''
      wait_for(20) { (output << read_available(reader)) =~ /Child process delayed_job\.3 \(pid \d+\) started/ }
      job = enqueue_process_job(ProcessJobs::SleepJob.new('after the crash loop', 0))
      wait_for { reload_job(job).nil? }
      Process.kill('TERM', -pid)
      status, rest = wait_for_launcher(pid, reader)
      output << rest
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status).to be_success, output
      waits = output.scan(/died [\d.]+s after starting \((\d) time\(s\) in a row\); waiting ([\d.]+)s before replacing it/)
      expect(waits).to eq [%w[1 0.25], %w[2 0.5], %w[3 1]]
      expect(elapsed).to be >= 1.75 # 0.25 + 0.5 + 1 seconds of waiting.
      expect(ProcessHelpers::Run.where(:key => 'after the crash loop').count).to eq 1
    end

    it 'does not hold up replacing a healthy sibling that dies meanwhile' do
      job = enqueue_process_job(ProcessJobs::SleepJob.new('long', 30), :queue => 'healthy')
      pid, reader = spawn_launcher(:pools => [[['crash'], 1], [['healthy'], 1]], :crash_queue => 'crash', :respawn_delay_unit => unit,
                                   :worker => worker_settings.merge(:shutdown_timeout => 1))
      output = +''
      wait_for(30) { (output << read_available(reader)) =~ /waiting 2s before replacing it/ }
      healthy = reload_job(job).locked_by[/pid:(\d+)/, 1].to_i
      killed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill('KILL', healthy)
      wait_for(5) { (output << read_available(reader)) =~ /Recovered 1 job\(s\) left locked by child process delayed_job\.\d+ \(pid #{healthy}\)/ }
      recovered_after = Process.clock_gettime(Process::CLOCK_MONOTONIC) - killed_at
      wait_for(5) { (output << read_available(reader)).scan(/started queues=healthy/).size == 2 }
      replaced_after = Process.clock_gettime(Process::CLOCK_MONOTONIC) - killed_at
      replacement = output.scan(/Child process (delayed_job\.\d+) \(pid \d+\) started queues=healthy/).last.first
      wait_for(5) { (output << read_available(reader)) =~ /Worker\(#{replacement} .*\)\] Starting job worker/ }
      Process.kill('TERM', -pid)
      status, rest = wait_for_launcher(pid, reader)
      output << rest

      expect(status).to be_success, output
      # Reaped and recovered at once, not after the crashing sibling's 2s
      # delay; replaced after at most its own (it was up under 10s: 0.25s).
      expect(recovered_after).to be < 1.5
      expect(replaced_after).to be < 3
      job = reload_job(job)
      expect([job.attempts, job.locked_by]).to eq [1, nil]
    rescue RuntimeError => error
      raise "#{error.message}\nOutput:\n#{output}"
    ensure
      reader.close if reader && !reader.closed?
      Process.kill('KILL', -pid) rescue nil
    end

    it 'stops waiting when the launcher is stopped' do
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :crash_on_start => 100, :respawn_delay_unit => unit,
                                   :worker => worker_settings)
      output = +''
      wait_for(20) { (output << read_available(reader)) =~ /waiting 1s before replacing it/ }
      stopped_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill('TERM', pid)
      status, rest = wait_for_launcher(pid, reader)
      output << rest
      expect(status).to be_success, output
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - stopped_at).to be < 3
      expect(output).not_to match(/Child process delayed_job\.3 \(pid \d+\) started/)
    end
  end

  context 'with several threads per worker process' do
    it 'recovers the jobs of every thread of the dead worker' do
      jobs = Array.new(3) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("slow#{i}", 30)) }
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :threads => 4, :worker => worker_settings)
      wait_for { ProcessHelpers::Job.where.not(:locked_by => nil).count == 3 }
      child = ProcessHelpers::Job.where.not(:locked_by => nil).first.locked_by[/pid:(\d+)/, 1].to_i
      Process.kill('KILL', child)
      # Recovered (rescheduled about 6s later), then stop before they rerun.
      wait_for { jobs.all? { |j| reload_job(j).attempts == 1 } }
      Process.kill('TERM', -pid)
      status, output = wait_for_launcher(pid, reader)

      expect(status).to be_success
      expect(output).to include 'Recovered 3 job(s) left locked by child process delayed_job.0'
      jobs = jobs.map { |j| reload_job(j) }
      expect(jobs.map(&:locked_by)).to eq [nil, nil, nil]
      expect(jobs.map(&:attempts)).to eq [1, 1, 1]
      expect(jobs.map(&:last_error)).to all(start_with('Child process delayed_job.0'))
    end
  end

  it 'leaves the jobs of the other, healthy worker processes alone' do
    slow = enqueue_process_job(ProcessJobs::SleepJob.new('survivor', 1), :queue => 'slow')
    pid, reader = spawn_launcher(:pools => [[['slow'], 1], [['kill'], 1]], :worker => worker_settings)
    wait_for { reload_job(slow).locked_by }
    healthy = reload_job(slow).locked_by
    victim = enqueue_process_job(ProcessJobs::KillJob.new('victim', 'KILL'), :queue => 'kill')
    wait_for { reload_job(victim).attempts == 1 }
    healthy_pid = healthy[/pid:(\d+)/, 1].to_i
    wait_for { reload_job(slow).nil? }
    expect(Process.kill(0, healthy_pid)).to eq 1 # Still running: only the dead worker was replaced.
    Process.kill('TERM', -pid)
    status, output = wait_for_launcher(pid, reader)

    expect(status).to be_success
    expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.1/)
    # The healthy worker finished its job, undisturbed.
    expect(ProcessHelpers::Run.where(:key => 'survivor').count).to eq 1
    expect(reload_job(slow)).to be_nil
    victim = reload_job(victim)
    expect(victim.attempts).to eq 1
    expect(victim.last_error).to start_with 'Child process delayed_job.1'
    expect(healthy).to start_with 'delayed_job.0'
  end
end
