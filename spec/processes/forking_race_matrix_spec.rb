require 'helper'
require_relative 'helpers'

# Races and edge cases of a real forking launcher (no mold): the shutdown
# timeout's kill, signals while child processes boot, respawns and failed
# forks, pidfiles and a parent that dies.
describe 'A forking launcher under races', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1} }
  let(:pid_file) { File.join(File.dirname(@process_db), 'pids', 'delayed_job.pid') }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def child_pids(output)
    output.scan(/Child process delayed_job\.\d+ \(pid (\d+)\) started/).flatten.map(&:to_i)
  end

  def locker_pid(job)
    reload_job(job).locked_by[/pid:(\d+)/, 1].to_i
  end

  # Reads output until it matches; returns the match.
  def wait_for_output(output, reader, pattern, timeout = 15)
    wait_for(timeout) { (output << read_available(reader)).match(pattern) }
  rescue RuntimeError => error
    raise "#{error.message}: #{pattern.inspect}\nOutput:\n#{output}"
  end

  # Spawns the launcher; the block gets [pid, reader, output]. Kills what's
  # left of its process group afterwards, and the given extra pids.
  def with_launcher(options)
    pid, reader = spawn_launcher(options)
    yield pid, reader, +''
  ensure
    reader.close if reader && !reader.closed?
    Process.kill('KILL', -pid) rescue nil
    Array(@extra_pids).each { |extra| Process.kill('KILL', extra) rescue nil }
  end

  describe "the shutdown timeout's kill" do
    # The crashing pool's replacement is pending (back-off) when the kill
    # comes: it must be dropped, not forked mid-kill.
    it 'drops a replacement pending its back-off, kills the frozen child, and exits 1 with its job recovered once' do
      job = enqueue_process_job(ProcessJobs::FreezeJob.new('frozen'), :queue => 'healthy')
      options = {:pools => [[['crash'], 1], [['healthy'], 1]], :crash_queue => 'crash', :respawn_delay_unit => 2,
                 :shutdown_timeout => 0, :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for { reload_job(job).locked_by }
        wait_for_output(output, reader, /waiting [\d.]+s before replacing it/)
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 25)
        output << rest

        expect(status.exitstatus).to eq(1), output
        expect(output).to include 'exited forcefully after 10 second timeout'
        expect(output.scan(/Kill invoked/).size).to eq 1
        expect(output).not_to include 'No child processes found'
        # No replacement for the crashing pool after the stop.
        expect(output.scan(/started queues=crash/).size).to eq 1
        expect(output).not_to match(/was SIGKILLed \(e\.g\. by the OOM killer\)/)
        job = reload_job(job)
        expect([job.locked_by, job.attempts]).to eq [nil, 1]
      end
    end

    # The child got TERM while booting (recorded by its capture traps) but
    # is still in after_fork when the kill fires.
    it 'kills and reaps a child still booting, and exits 1' do
      with_launcher(:processes => 2, :startup_delay => 30, :shutdown_timeout => 0, :worker => worker_settings) do |pid, reader, output|
        wait_for { (output << read_available(reader)).scan(/worker \d+ starting up/).size == 2 }
        Process.kill('TERM', pid)
        started = monotonic_now
        status, rest = wait_for_launcher(pid, reader, 25)
        output << rest

        expect(status.exitstatus).to eq(1), output
        expect(monotonic_now - started).to be_between(9, 15)
        expect(output.scan(/Child process delayed_job\.\d \(pid \d+\) exited: pid \d+ SIGKILL \(signal 9\)/).size).to eq 2
        expect(output).to include 'exited forcefully after 10 second timeout'
        expect(output).not_to include 'exited gracefully'
      end
    end

    # TERM's kill is due in 30s; QUIT schedules one in 10s, which wins.
    it 'is brought forward by a QUIT after TERM' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      job = enqueue_process_job(ProcessJobs::FreezeJob.new('frozen'))
      with_launcher(:processes => 2, :shutdown_timeout => 20, :worker => worker_settings) do |pid, reader, output|
        wait_for { reload_job(job).locked_by }
        Process.kill('TERM', pid)
        wait_for_output(output, reader, /Received SIGTERM/)
        Process.kill('QUIT', pid)
        quit_at = monotonic_now
        status, rest = wait_for_launcher(pid, reader, 25)
        output << rest

        expect(status.exitstatus).to eq(1), output
        expect(monotonic_now - quit_at).to be < 15
        expect(output).to include 'exited forcefully after 10 second timeout'
        expect(output).not_to include 'after 30 second timeout'
        job = reload_job(job)
        expect([job.locked_by, job.attempts]).to eq [nil, 1]
      end
    end

    # HUP schedules the kill; TERM later must not postpone or repeat it.
    # The idle sibling has already exited and been reaped when it fires.
    it 'fires once after HUP then TERM, skips the child that already exited, and deletes the pidfile' do
      job = enqueue_process_job(ProcessJobs::FreezeJob.new('frozen'))
      options = {:processes => 2, :shutdown_timeout => 0, :pid_file => pid_file, :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for { reload_job(job).locked_by }
        stubborn = locker_pid(job)
        Process.kill('HUP', pid)
        wait_for_output(output, reader, /Child process delayed_job\.\d \(pid (?!#{stubborn}\))\d+\) exited: pid \d+ exit 0/)
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 25)
        output << rest

        expect(status.exitstatus).to eq(1), output
        expect(output).to include 'Received SIGHUP'
        expect(output).to include 'Received SIGTERM'
        expect(output.scan(/Kill invoked/).size).to eq 1
        expect(output).to include 'exited forcefully after 10 second timeout'
        expect(output.scan(/Sent SIGKILL to child process/).size).to eq 1
        expect(output).not_to include 'not sent SIGKILL'
        expect(output).to match(/\(pid #{stubborn}\) exited: pid #{stubborn} SIGKILL \(signal 9\)/)
        expect(File.exist?(pid_file)).to be false
        job = reload_job(job)
        expect([job.locked_by, job.attempts]).to eq [nil, 1]
      end
    end

    # The run loop hangs recovering the idle child's locks (a hung database
    # call): only the kill timer's backstop gets the launcher out. exit!
    # skips deleting the pidfile, but its flock goes with the process.
    it 'exits 1 through the backstop when the run loop is stuck, leaving a pidfile a new launcher can take over' do
      job = enqueue_process_job(ProcessJobs::StubbornJob.new('stubborn'))
      options = {:processes => 2, :shutdown_timeout => 0, :hang_recovery => true, :pid_file => pid_file, :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for { reload_job(job).locked_by }
        Process.kill('TERM', pid)
        wait_for_output(output, reader, /recovery hanging/)
        status, rest = wait_for_launcher(pid, reader, 28)
        output << rest

        expect(status.exitstatus).to eq(1), output
        expect(output).to include 'Kill invoked after 10 second timeout'
        expect(output).to match(/still running 10s after the kill; exiting - pid #{pid}/)
        expect(output).not_to include 'exited forcefully'
        expect(File.read(pid_file)).to eq "#{pid}\n" # Left behind by exit!.
        # Never recovered: left to max_run_time.
        expect(reload_job(job).locked_by).not_to be_nil

        status, again = run_launcher({:processes => 2, :pid_file => pid_file, :exit_on_complete => true, :worker => worker_settings}, 20)
        expect(status).to be_success, again
        expect(again).not_to include 'already running'
        expect(File.exist?(pid_file)).to be false
      end
    end
  end

  describe 'signals while child processes boot' do
    it 'quits children that got QUIT (sent to the parent only) while booting, without waiting for the kill' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      with_launcher(:processes => 2, :startup_delay => 2, :worker => worker_settings) do |pid, reader, output|
        wait_for { (output << read_available(reader)).scan(/worker \d+ starting up/).size == 2 }
        Process.kill('QUIT', pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        expect(output.scan(/Received SIGQUIT while starting/).size).to eq 2
        expect(output.scan(/Received SIGQUIT\. Interrupting/).size).to eq 1
        expect(output).not_to include 'Kill invoked'
      end
    end

    # TERM to the whole group while the children still run the launcher's
    # inherited traps: each records it once, and only the parent forwards.
    it 'stops children signalled by the process group before they replace the inherited traps' do
      with_launcher(:processes => 3, :capture_delay => 1.5, :worker => worker_settings) do |pid, reader, output|
        wait_for(10) { (output << read_available(reader)).scan(/capturing signals/).size == 3 }
        Process.kill('TERM', -pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        expect(output.scan(/Received SIGTERM while starting/).size).to eq 3
        expect(output.scan(/Received SIGTERM\. Waiting for workers/).size).to eq 1
        expect(output.scan(/exited: pid \d+ exit 0/).size).to eq 3
      end
    end
  end

  describe 'respawning' do
    # Two healthy children die at once while the crashing pool waits out its
    # back-off: both are recovered and replaced; TERM then stops everything.
    it 'recovers and replaces several children SIGKILLed at once beside a crash-looping pool' do
      jobs = Array.new(2) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("long#{i}", 30), :queue => 'healthy') }
      options = {:pools => [[['crash'], 1], [['healthy'], 2]], :crash_queue => 'crash', :respawn_delay_unit => 0.25,
                 :shutdown_timeout => 1, :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for { jobs.all? { |job| reload_job(job).locked_by } }
        wait_for_output(output, reader, /waiting [\d.]+s before replacing it/)
        victims = jobs.map { |job| locker_pid(job) }
        expect(victims.uniq.size).to eq 2
        victims.each { |victim| Process.kill('KILL', victim) }
        wait_for(10) { (output << read_available(reader)).scan(/started queues=healthy/).size == 4 }
        wait_for(10) { jobs.all? { |job| reload_job(job).attempts == 1 && reload_job(job).locked_by } }
        replacements = jobs.map { |job| locker_pid(job) }
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 25)
        output << rest

        expect(status).to be_success, output
        victims.each do |victim|
          expect(output).to match(/Recovered 1 job\(s\) left locked by child process delayed_job\.\d+ \(pid #{victim}\)/)
        end
        expect(output.scan(/was SIGKILLed \(e\.g\. by the OOM killer\); replacing it/).size).to eq 2
        expect((victims + replacements + child_pids(output)).uniq.select { |child| alive?(child) }).to be_empty
        jobs.each { |job| expect([reload_job(job).locked_by, reload_job(job).attempts]).to eq [nil, 1] }
      end
    end

    # The first child crashes; forking its replacement fails twice (EAGAIN)
    # before one succeeds, backing off further each time.
    it 'retries a failed respawn fork with growing back-off until it succeeds' do
      options = {:processes => 1, :pools => [[[], 1]], :crash_on_start => 1, :fail_forks => [2, 3], :respawn_delay_unit => 0.25,
                 :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for_output(output, reader, /Child process delayed_job\.1 \(pid \d+\) started/)
        job = enqueue_process_job(ProcessJobs::SleepJob.new('after the failed forks', 0))
        wait_for { reload_job(job).nil? }
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        retries = output.scan(/Could not fork a replacement for child process delayed_job\.0 \(pid \d+\): Errno::EAGAIN.*retrying in ([\d.]+)s/)
        expect(retries.flatten).to eq %w[0.5 1.0]
        expect(output).to include 'waiting 0.25s before replacing it'
        expect(ProcessHelpers::Run.where(:key => 'after the failed forks').count).to eq 1
      end
    end

    # With every respawn fork failing, the launcher has no child left and
    # only pending retries: TERM must still end it promptly.
    it 'stops promptly on TERM while only failed-fork retries are pending' do
      options = {:processes => 1, :pools => [[[], 1]], :crash_on_start => 1, :fail_forks_from => 2, :respawn_delay_unit => 0.25,
                 :worker => worker_settings}
      with_launcher(options) do |pid, reader, output|
        wait_for_output(output, reader, /fork 4 failing/)
        stopped_at = monotonic_now
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        expect(monotonic_now - stopped_at).to be < 3
        expect(output).not_to include 'No child processes found'
        expect(child_pids(output).size).to eq 1
      end
    end

    # A transient EAGAIN while forking the initial children should be
    # retried like a failed respawn, not crash the launcher.
    it 'retries a fork that fails while booting the initial children' do
      job = enqueue_process_job(ProcessJobs::SleepJob.new('after the failed boot fork', 0))
      with_launcher(:processes => 2, :fail_forks => [2], :respawn_delay_unit => 0.25, :worker => worker_settings) do |pid, reader, output|
        crashed = nil
        wait_for { (output << read_available(reader)).scan(/\) started/).size == 2 || (crashed = Process.waitpid2(pid, Process::WNOHANG)) }
        expect(crashed).to be_nil, output
        wait_for { reload_job(job).nil? }
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        expect(output).to include 'Could not fork a replacement'
      end
    end

    # Exit 0 without being asked to stop (exit_on_complete off): replaced,
    # and its leftover lock released with no attempt counted.
    it 'replaces a child that exits 0 by itself, releasing its job with attempts unchanged' do
      marker = File.join(File.dirname(@process_db), 'exited-once')
      job = enqueue_process_job(ProcessJobs::ExitOnceJob.new('exit once', 0, marker))
      with_launcher(:processes => 1, :pools => [[[], 1]], :respawn_delay_unit => 0.25, :worker => worker_settings) do |pid, reader, output|
        wait_for { reload_job(job).nil? }
        Process.kill('TERM', pid)
        status, rest = wait_for_launcher(pid, reader, 20)
        output << rest

        expect(status).to be_success, output
        expect(output).to match(/Child process delayed_job\.0 \(pid \d+\) exited: pid \d+ exit 0/)
        expect(output).to match(/Child process delayed_job\.1 \(pid \d+\) started/)
        expect(output).not_to include 'Recovered'
        expect(ProcessHelpers::Run.where(:key => 'exit once').count).to eq 1
      end
    end
  end

  describe 'exit_on_complete (workoff) with several processes' do
    # Stopped from the start, the launcher doesn't replace the crashed child;
    # the others drain the queue, and the crashed job is recovered.
    it 'recovers the job of a child that crashed, lets the others drain the queue, and exits' do
      crash = enqueue_process_job(ProcessJobs::ExitJob.new('crash', 3))
      jobs = Array.new(6) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("drain#{i}", 0.2)) }
      status, output = run_launcher({:processes => 3, :exit_on_complete => true, :worker => worker_settings}, 25)

      expect(status).to be_success, output
      expect(output).to match(/exited: pid \d+ exit 3/)
      expect(child_pids(output).size).to eq 3 # Not replaced.
      expect(jobs.map { |job| reload_job(job) }.compact).to be_empty
      crash = reload_job(crash)
      expect([crash.locked_by, crash.attempts]).to eq [nil, 1]
      expect(child_pids(output).select { |child| alive?(child) }).to be_empty
    end
  end

  describe 'a parent SIGKILLed' do
    # The kill timer dies with the parent: the orphaned child must still
    # give up on the stubborn job (its own interrupt grace) and exit.
    it 'during a shutdown timeout leaves no child running a job that ignores the interrupt' do
      job = enqueue_process_job(ProcessJobs::StubbornJob.new('stubborn'))
      with_launcher(:processes => 2, :shutdown_timeout => 1, :worker => worker_settings) do |pid, reader, output|
        wait_for { reload_job(job).locked_by }
        wait_for { child_pids(output << read_available(reader)).size == 2 }
        children = child_pids(output)
        @extra_pids = children
        Process.kill('TERM', pid)
        wait_for_output(output, reader, /Shutdown timeout of 1s exceeded/)
        Process.kill('KILL', pid)
        Process.waitpid(pid)
        wait_for(15) { children.none? { |child| alive?(child) } }
        output << read_to_eof(reader, 2)

        expect(output).not_to include 'Kill invoked'
        expect(ProcessHelpers::Run.where(:key => 'stubborn').count).to eq 0
      end
    end

    # The children are draining after TERM when the parent dies: they still
    # finish their jobs and exit, and the pidfile's lock is released.
    it 'while children drain after TERM lets them finish, and frees the pidfile lock once they exit' do
      jobs = Array.new(2) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("drain#{i}", 3)) }
      with_launcher(:processes => 2, :pid_file => pid_file, :worker => worker_settings) do |pid, reader, output|
        wait_for { jobs.all? { |job| reload_job(job).locked_by } }
        children = jobs.map { |job| locker_pid(job) }
        @extra_pids = children
        Process.kill('TERM', pid)
        wait_for_output(output, reader, /Received SIGTERM/)
        Process.kill('KILL', pid)
        Process.waitpid(pid)

        status, refused = run_launcher({:processes => 1, :pid_file => pid_file}, 20)
        expect(status).not_to be_success
        expect(refused).to include 'already running'

        wait_for(15) { children.none? { |child| alive?(child) } }
        output << read_to_eof(reader, 2)
        expect(ProcessHelpers::Run.where(:key => %w[drain0 drain1]).count).to eq 2
        jobs.each { |job| expect(reload_job(job)).to be_nil }

        status, again = run_launcher({:processes => 1, :pid_file => pid_file, :exit_on_complete => true}, 20)
        expect(status).to be_success, again
      end
    end
  end
end
