require 'helper'

# A child process that dies soon after starting is replaced after a delay
# that doubles with each such death in a row (see Launcher::Forking). The
# delay is waited out in the run loop, which meanwhile keeps reaping and
# replacing the other child processes.
describe Delayed::Launcher::Forking, 'replacing child processes that keep dying' do
  subject(:launcher) { described_class.new(:processes => 2) }

  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }
  let(:crashed) { double('Process::Status', :signaled? => false, :termsig => nil, :exitstatus => 3, :success? => false, :to_s => 'exit 3') }
  let(:now) { [1000.0] }
  let(:pids) { (200..300).to_a }
  let(:delays) { [] }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(launcher).to receive(:recover_jobs_of_worker)
    allow(launcher).to receive(:monotonic_now) { now.first }
    allow(launcher).to receive(:fork_worker) { pids.shift }
    launcher.instance_variable_set(:@stopped, false)
  end

  def start_child
    launcher.send(:add_worker, {})
  end

  # Child `pid` exits after `uptime` seconds; returns its replacement's pid,
  # once any delay before it has passed.
  def dies_after(pid, uptime)
    now[0] += uptime
    launcher.send(:workers).delete(pid)
    new_pid = launcher.send(:replace_worker, 'delayed_job.x', pid, {}, crashed)
    return (delays << 0) && new_pid if new_pid
    at, = launcher.send(:pending_replacements).last
    delays << (at - now[0]).round
    now[0] = at
    before = launcher.send(:workers).keys
    launcher.send(:replace_due_workers)
    (launcher.send(:workers).keys - before).first
  end

  it 'replaces a child process that ran long enough at once' do
    pid = start_child
    expect(dies_after(pid, 30)).to eq 201
    expect(delays).to eq [0]
  end

  it 'delays replacing a child process that died within RESPAWN_MIN_UPTIME of starting, and says so' do
    logged = []
    allow(logger).to receive(:warn) { |m| logged << m }
    pid = start_child
    expect(launcher.send(:replace_worker, 'delayed_job.x', pid, {}, crashed)).to be_nil
    expect(launcher.send(:workers).keys).to eq [pid] # Not replaced yet.
    expect(logged).to eq ['Child process delayed_job.x (pid 200) died 0.0s after starting (1 time(s) in a row); waiting 1s before replacing it']
  end

  it 'doubles the delay with each quick death in a row, up to RESPAWN_MAX_DELAY' do
    pid = start_child
    9.times { pid = dies_after(pid, 1) }
    expect(delays).to eq [1, 2, 4, 8, 16, 32, 60, 60, 60]
  end

  context 'with a lower respawn_delay_unit (a test setting)' do
    around do |example|
      described_class.respawn_delay_unit = 0.25
      example.run
    ensure
      described_class.respawn_delay_unit = 1
    end

    it 'scales the delays, still capped at RESPAWN_MAX_DELAY' do
      expect((1..10).map { |streak| launcher.send(:respawn_delay, streak) }).to eq [0.25, 0.5, 1, 2, 4, 8, 16, 32, 60, 60]
    end

    it 'says the fractional delay' do
      logged = []
      allow(logger).to receive(:warn) { |text| logged << text }
      launcher.send(:replace_worker, 'delayed_job.x', start_child, {}, crashed)
      expect(logged.last).to end_with 'waiting 0.25s before replacing it'
    end
  end

  it 'defaults respawn_delay_unit to 1 second' do
    expect(described_class.respawn_delay_unit).to eq 1
  end

  it 'resets the delay once a replacement stays up' do
    pid = start_child
    3.times { pid = dies_after(pid, 1) }
    pid = dies_after(pid, 60)
    dies_after(pid, 1)
    expect(delays).to eq [1, 2, 4, 0, 1]
  end

  it 'counts the uptime from the start, not including the delay before it' do
    pid = start_child
    pid = dies_after(pid, 1)
    dies_after(pid, described_class::RESPAWN_MIN_UPTIME + 1)
    expect(delays).to eq [1, 0]
  end

  it 'keeps a separate streak for each line of replacements' do
    healthy = start_child
    now[0] += 100
    crashing = start_child
    crashing = dies_after(crashing, 1)
    crashing = dies_after(crashing, 1)
    dies_after(healthy, 0)
    dies_after(crashing, 1)
    expect(delays).to eq [1, 2, 0, 4]
  end

  describe '#replace_due_workers' do
    it 'replaces only the child processes whose delay has passed, earliest first' do
      a = start_child
      b = start_child
      launcher.send(:workers).clear
      launcher.send(:replace_worker, 'delayed_job.a', a, {:queues => ['a']}, crashed) # Due in 1s.
      now[0] += 0.5
      launcher.send(:replace_worker, 'delayed_job.b', b, {:queues => ['b']}, crashed) # Due in 1.5s.
      now[0] += 0.6
      launcher.send(:replace_due_workers)
      expect(launcher.send(:workers).values.map { |_, o| o[:queues] }).to eq [['a']]
      now[0] += 1
      launcher.send(:replace_due_workers)
      expect(launcher.send(:workers).values.map { |_, o| o[:queues] }).to eq [['a'], ['b']]
      expect(launcher.send(:pending_replacements)).to be_empty
    end

    it 'drops pending replacements when the launcher is stopped' do
      pid = start_child
      launcher.send(:replace_worker, 'delayed_job.x', pid, {}, crashed)
      launcher.instance_variable_set(:@stopped, true)
      now[0] += 100
      expect(launcher).not_to receive(:add_worker)
      launcher.send(:replace_due_workers)
      expect(launcher.send(:pending_replacements)).to be_empty
    end

    it 'publishes process_spawned with the pid replaced and the delay' do
      events = payloads_of(:process_spawned)
      first = start_child
      second = dies_after(first, 1)
      dies_after(second, 1)
      expect(events.map { |e| e.slice(:replaces_pid, :delay) }).to eq [
        {:replaces_pid => nil, :delay => 0}, {:replaces_pid => first, :delay => 1}, {:replaces_pid => second, :delay => 2}
      ]
    end
  end

  describe 'when forking a replacement fails' do
    let(:reported) { Concurrent::Array.new }

    before { Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] } }

    def fail_forks(count, error = Errno::EAGAIN)
      failures = count
      allow(launcher).to receive(:fork_worker) do
        if failures > 0
          failures -= 1
          raise error
        end
        pids.shift
      end
    end

    it 'logs and reports it, and retries after a back-off delay' do
      logged = []
      allow(logger).to receive(:error) { |m| logged << m }
      fail_forks(1)
      expect(launcher.send(:replace_worker, 'delayed_job.x', 999, {}, crashed)).to be_nil
      expect(logged).to eq ['Could not fork a replacement for child process delayed_job.x (pid 999): ' \
                            "Errno::EAGAIN: #{Errno::EAGAIN.new.message}; retrying in 1s"] # Its text varies by platform.
      expect(reported.map { |e, i| [e.class, i] }).to eq [[Errno::EAGAIN, {:context => 'Forking', :worker => 'delayed_job.x', :pid => 999}]]
      now[0] += 1
      launcher.send(:replace_due_workers)
      expect(launcher.send(:workers).keys).to eq [200]
    end

    it 'backs off further while forking keeps failing' do
      fail_forks(4, Errno::ENOMEM)
      launcher.send(:replace_worker, 'delayed_job.x', 999, {}, crashed)
      waits = []
      until launcher.send(:pending_replacements).empty?
        at, = launcher.send(:pending_replacements).first
        waits << (at - now[0]).round
        now[0] = at
        launcher.send(:replace_due_workers)
      end
      expect(waits).to eq [1, 2, 4, 8]
      expect(launcher.send(:workers).keys).to eq [200]
    end

    it 'keeps the launcher running' do
      only = start_child
      fail_forks(1)
      allow(launcher).to receive(:monotonic_now).and_call_original
      allow(launcher).to receive(:sleep) { |s| Kernel.sleep(s) }
      calls = 0
      allow(Process).to receive(:wait2) do |*args|
        calls += 1
        next [only, crashed] if calls == 1
        next nil if args == [-1, Process::WNOHANG]
        sleep 0.01 until launcher.instance_variable_get(:@stopped) # Children running: blocks.
        raise Errno::ECHILD
      end
      launcher.send(:started_at)[only] -= 100 # Long-lived: replaced at once, and the fork fails.
      thread = Thread.new { launcher.send(:run_loop) }
      thread.report_on_exception = false
      wait_until(5) { !thread.alive? || (launcher.send(:workers).keys - [only]).any? }
      expect(thread).to be_alive # The failed fork didn't end the run loop,
      expect(launcher.send(:workers).keys).to eq [pids.first - 1] # and was retried: the next pid forked.
      launcher.instance_variable_set(:@stopped, true)
      launcher.send(:workers).clear
      expect { Timeout.timeout(5) { thread.join } }.not_to raise_error
    end
  end

  it 'treats a child process with no recorded start as long-lived' do
    expect(launcher.send(:replace_worker, 'delayed_job.x', 999, {}, crashed)).to eq 200
  end

  describe 'the run loop' do
    before { allow(launcher).to receive(:monotonic_now).and_call_original }

    # Process.wait2 in the run loop: the given exits, in order, as soon as
    # asked (or never, if `nil`); then blocks until stopped.
    def exits(*sequence)
      calls = []
      allow(Process).to receive(:wait2) do |*args|
        calls << args
        nohang = args == [-1, Process::WNOHANG]
        next_exit = sequence.first
        if next_exit
          sequence.shift
        elsif nohang
          nil
        else
          raise Errno::ECHILD
        end
      end
      calls
    end

    it 'reaps and replaces a healthy child process at once while another waits to be replaced' do
      crashing = start_child
      healthy = start_child
      launcher.send(:started_at)[healthy] -= 100 # Up for a while.
      allow(launcher).to receive(:sleep).and_call_original
      healthy_status = double('Process::Status', :signaled? => false, :termsig => nil, :success? => false, :to_s => 'exit 1')
      replaced = []
      allow(launcher).to receive(:add_worker).and_wrap_original do |m, options, **kwargs|
        replaced << [options, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
        m.call(options, **kwargs)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exits([crashing, crashed], [healthy, healthy_status])
      thread = Thread.new { launcher.send(:run_loop) }
      wait_until(5) { replaced.size == 1 }
      expect(replaced.first.last - started).to be < 0.5 # Not after the crashing one's 1s delay.
      wait_until(5) { replaced.size == 2 }
      expect(replaced.last.last - started).to be >= 0.9 # The crashing one, after its delay.
      launcher.instance_variable_set(:@stopped, true)
      launcher.send(:workers).clear
      Timeout.timeout(5) { thread.join }
    end

    it 'recovers the jobs of a child process that died while another waits to be replaced' do
      crashing = start_child
      other = start_child
      exits([crashing, crashed], [other, crashed])
      allow(launcher).to receive(:sleep) { |s| Kernel.sleep(s) }
      thread = Thread.new { launcher.send(:run_loop) }
      wait_until(0.5) { launcher.send(:pending_replacements).size == 2 }
      expect(launcher).to have_received(:recover_jobs_of_worker).twice
      launcher.instance_variable_set(:@stopped, true)
      launcher.send(:workers).clear
      Timeout.timeout(5) { thread.join }
    end

    it 'waits out a delay even with no child process left to wait for' do
      only = start_child
      exits([only, crashed])
      allow(launcher).to receive(:sleep) { |s| Kernel.sleep(s) }
      thread = Thread.new { launcher.send(:run_loop) }
      wait_until(5) { launcher.send(:workers).size == 1 && !launcher.send(:workers).key?(only) }
      launcher.instance_variable_set(:@stopped, true)
      launcher.send(:workers).clear
      Timeout.timeout(5) { thread.join }
      expect(thread.value).to be_nil
    end

    it 'stops waiting, and exits, when stopped during a delay' do
      only = start_child
      exits([only, crashed])
      allow(launcher).to receive(:sleep) { |s| Kernel.sleep(s) }
      expect(launcher).to receive(:add_worker).never
      thread = Thread.new { launcher.send(:run_loop) }
      wait_until(5) { launcher.send(:pending_replacements).any? }
      launcher.instance_variable_set(:@stopped, true)
      expect(Timeout.timeout(2) { thread.join }).to eq thread
    end
  end
end
