require 'helper'
require 'logger'
require 'tmpdir'

# Delayed::Launcher::Mold#run in a real forked process, with a stub launcher
# and real Mold::Pipes: the spec process plays the parent, writing fork
# records and reading status lines.
describe Delayed::Launcher::Mold, :fork do
  # What Mold uses of the forking launcher. Its #fork_mold_child forks a
  # child that reports "c <pid> <worker index> <pool index> <generation>
  # <ios to close>", then exits with the worker index as its status, or
  # (worker index 0) sleeps until killed.
  let(:launcher_class) do
    Class.new do
      attr_reader :child_signals, :logger

      def initialize(pipes, logger)
        @pipes = pipes
        @logger = logger
        @child_signals = []
      end

      def warmup_heap; end

      # sqlite3 warns, in each forked process, about the spec process's
      # database connections it closes there.
      def quiet_fork(&block)
        verbose = $VERBOSE
        $VERBOSE = nil
        fork(&block)
      ensure
        $VERBOSE = verbose
      end

      def child_signal(signal)
        @child_signals << signal
      end

      def fork_mold_child(worker_index, pool_index, generation, close_ios)
        raise Errno::EAGAIN, 'stub' if worker_index == 99
        pipes = @pipes
        quiet_fork do
          close_ios.each(&:close)
          %w[CHLD URG TERM].each { |signal| Signal.trap(signal, 'DEFAULT') }
          pipes.report("c #{Process.pid} #{worker_index} #{pool_index} #{generation} #{close_ios.size}")
          sleep if worker_index.zero?
          exit!(worker_index)
        end
      end
    end
  end

  let(:pipes) { described_class::Pipes.new }
  let(:lines) { [] }

  around do |example|
    Dir.mktmpdir('dj-mold') do |dir|
      @log_path = File.join(dir, 'mold.log')
      @spawned = []
      example.run
    ensure
      children = lines.select { |type, *| type == 'f' }.map { |line| line[2] }
      (@spawned + children).each do |pid|
        Process.kill('KILL', pid) rescue nil
      end
      @spawned.each { |pid| Process.wait(pid) rescue nil }
    end
  end

  # Forks a process running the mold; `setup` runs in it first.
  def start_mold(info = {}, &setup)
    log_path = @log_path
    mold_pipes = pipes
    launcher = launcher_class
    info = {:promoted_pid => 4242, :generation => 1, :exit_when_retired => false}.merge(info)
    pid = launcher.allocate.quiet_fork do
      status = 0
      begin
        mold_pipes.close_parent_ends
        logger = Logger.new(log_path)
        setup&.call
        described_class.new(launcher.new(mold_pipes, logger), mold_pipes, info).run
      rescue Exception => error # rubocop:disable Lint/RescueException
        File.write(log_path, "#{error.class}: #{error.message}\n#{error.backtrace.first(5).join("\n")}", :mode => 'a')
        status = 1
      ensure
        exit!(status)
      end
    end
    @spawned << pid
    pid
  end

  # Reads status lines until one matches; returns its integer arguments.
  def wait_for_line(type, *prefix, timeout: 10)
    deadline = Time.now + timeout
    loop do
      found = lines.find { |line_type, *args| line_type == type && args.first(prefix.size) == prefix }
      return found.drop(1) if found
      raise "no #{[type, *prefix].join(' ').inspect} status line in #{timeout}s; got #{lines.inspect}" if Time.now > deadline
      pipes.each_status(0.1) { |*line| lines << line }
    end
  end

  # Status lines of `type` received, after reading for `seconds`.
  def count_lines(type, seconds = 0)
    deadline = Time.now + seconds
    pipes.each_status(0.1) { |*line| lines << line } while Time.now < deadline
    lines.count { |line_type, *| line_type == type }
  end

  # The mold's exit status, or nil if it still runs after `timeout`.
  def wait_for_exit(pid, timeout = 10)
    deadline = Time.now + timeout
    while Time.now < deadline
      _, status = Process.wait2(pid, Process::WNOHANG)
      if status
        @spawned.delete(pid)
        return status
      end
      pipes.each_status(0.05) { |*line| lines << line }
    end
    nil
  end

  def ready_mold(info = {}, &setup)
    pid = start_mold(info, &setup)
    expect(wait_for_line('m', pid)).to eq [pid, 4242]
    pid
  end

  # As when the parent dies: the last write end of the life pipe closes
  # (the status pipe stays open, to read what the mold reports).
  def close_life_pipe
    pipes.instance_variable_get(:@life_write).close
  end

  def log
    File.exist?(@log_path) ? File.read(@log_path) : ''
  end

  it 'reports "m" with the promoted child, and exits on EOF of the life pipe once the parent is gone' do
    pid = ready_mold
    expect(wait_for_exit(pid, 1.5)).to be_nil # Still waiting for work.
    close_life_pipe

    status = wait_for_exit(pid)
    expect(status).to be_success, log
  end

  it 'forks a child for a fork record, reports it with "f", and its exit with "x"' do
    pid = ready_mold
    pipes.request_fork(3, described_class::NO_POOL, 7)

    child, index = wait_for_line('f', pid).drop(1)
    expect(index).to eq 3
    # The mold's wake pipe is closed in the child.
    expect(wait_for_line('c', child)).to eq [child, 3, described_class::NO_POOL, 7, 2]
    expect(wait_for_line('x', pid, child)).to eq [pid, child, 3, nil]
    expect(wait_for_exit(pid, 0.5)).to be_nil # Still the active mold.
  end

  it 'reports a child killed by a signal with its signal number' do
    pid = ready_mold
    pipes.request_fork(0, 2, 1)
    child = wait_for_line('f', pid)[1]
    wait_for_line('c', child)
    Process.kill('KILL', child)

    expect(wait_for_line('x', pid, child)).to eq [pid, child, nil, 9]
  end

  it 'exits at once on URG when retired with exit_when_retired, leaving its children running' do
    pid = ready_mold(:exit_when_retired => true)
    pipes.request_fork(0, described_class::NO_POOL, 1)
    child = wait_for_line('f', pid)[1]
    wait_for_line('c', child)
    Process.kill('URG', pid)

    status = wait_for_exit(pid)
    expect(status).to be_success, log
    expect(Delayed::ProcessUtil.alive?(child)).to be true
    expect(lines.map(&:first)).not_to include 's' # Retired, not stopped.
  end

  it 'on URG without exit_when_retired, forks no more and exits once its children have' do
    pid = ready_mold
    pipes.request_fork(0, described_class::NO_POOL, 1)
    child = wait_for_line('f', pid)[1]
    wait_for_line('c', child)
    Process.kill('URG', pid)
    expect(wait_for_exit(pid, 1.5)).to be_nil
    pipes.request_fork(5, described_class::NO_POOL, 1)
    expect(count_lines('f', 1)).to eq 1

    Process.kill('KILL', child)
    status = wait_for_exit(pid)
    expect(status).to be_success, log
    expect(lines).to include ['x', pid, child, nil, 9]
    expect(count_lines('f')).to eq 1
  end

  it 'exits at once on URG without exit_when_retired when it has no children' do
    pid = ready_mold
    Process.kill('URG', pid)

    expect(wait_for_exit(pid)).to be_success
  end

  it 'reports "s" on TERM, forks no more, and exits once its children have' do
    pid = ready_mold
    pipes.request_fork(0, described_class::NO_POOL, 1)
    child = wait_for_line('f', pid)[1]
    wait_for_line('c', child)
    Process.kill('TERM', pid)

    expect(wait_for_line('s', pid)).to eq [pid]
    pipes.request_fork(6, described_class::NO_POOL, 1)
    expect(wait_for_exit(pid, 1.5)).to be_nil
    expect(count_lines('f')).to eq 1
    Process.kill('KILL', child)
    expect(wait_for_exit(pid)).to be_success
    expect(count_lines('s')).to eq 1
  end

  it 'reports a failed fork with "e" and its errno, and keeps forking' do
    pid = ready_mold
    pipes.request_fork(99, described_class::NO_POOL, 1)
    expect(wait_for_line('e', pid)).to eq [pid, 99, Errno::EAGAIN::Errno]
    pipes.request_fork(3, described_class::NO_POOL, 1)
    expect(wait_for_line('f', pid).last).to eq 3
    expect(log).to include 'could not fork child process 99: Errno::EAGAIN'
  end

  it 'reports "s" on TERM and exits at once when it has no children' do
    pid = ready_mold
    Process.kill('TERM', pid)

    expect(wait_for_line('s', pid)).to eq [pid]
    expect(wait_for_exit(pid)).to be_success
  end

  it 'warns about threads still running, except those marked fork safe' do
    pid = ready_mold do
      Thread.new { sleep }.name = 'plain-worker'
      Thread.new do
        Thread.current.thread_variable_set(:fork_safe, true)
        sleep
      end.name = 'safe-reaper'
      sleep 0.1 until Thread.list.all? { |thread| thread == Thread.current || thread.status == 'sleep' }
    end
    close_life_pipe
    expect(wait_for_exit(pid)).to be_success

    expect(log).to match(/Mold \(pid #{pid}\) has 1 other thread\(s\) running, which child processes won't have: plain-worker/)
    expect(log).not_to include 'safe-reaper'
  end

  it 'does not warn when every other thread is marked fork safe' do
    pid = ready_mold do
      Thread.new do
        Thread.current.thread_variable_set(:fork_safe, true)
        sleep
      end
      sleep 0.1 until Thread.list.size == 2 && Thread.list.all? { |thread| thread == Thread.current || thread.status == 'sleep' }
    end
    close_life_pipe
    expect(wait_for_exit(pid)).to be_success

    expect(log).not_to include 'other thread(s) running'
  end
end
