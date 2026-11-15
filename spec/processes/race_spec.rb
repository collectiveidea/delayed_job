require 'helper'
require_relative 'helpers'

# Races between real worker processes, their parent and signals.
describe 'Races between worker processes', :processes do
  include ProcessHelpers

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def child_pids(output)
    output.scan(/Child process delayed_job\.\d+ \(pid (\d+)\) started/).flatten.map(&:to_i)
  end

  # R3
  it 'run each job exactly once, with several processes and threads reserving at once' do
    jobs = Array.new(300) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("job#{i}", 0.01)) }
    status, output = run_launcher({:processes => 3, :threads => 4, :exit_on_complete => true,
                                   :worker => {:sleep_delay => 0.1}}, 120)

    expect(status).to be_success, output
    runs = ProcessHelpers::Run.all.to_a
    expect(runs.map(&:key).tally.values.uniq).to eq([1]), "jobs run more than once: #{runs.map(&:key).tally.select { |_, n| n > 1 }}"
    expect(runs.map(&:key)).to match_array(jobs.map { |j| YAML.load_dj(j.handler).key })
    expect(ProcessHelpers::Job.count).to eq 0
    expect(runs.map(&:pid).uniq.size).to be >= 2 # Several processes took part (one may start late),
    expect(runs.map { |r| [r.pid, r.worker] }.uniq.size).to be > 3 # with several threads.
  end

  # R5
  it 'stop cleanly, leaving no job run twice or locked, under a storm of signals' do
    seed = Integer(ENV.fetch('RACE_SEED', Random.new_seed))
    random = Random.new(seed)
    jobs = Array.new(60) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("job#{i}", 0.1 + (random.rand * 0.2))) }
    pid, reader = spawn_launcher(:processes => 3, :threads => 2, :worker => {:sleep_delay => 0.1})
    output = +''
    wait_for(10) { child_pids(output << read_available(reader)).size == 3 }
    seen = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      output << read_available(reader)
      seen |= child_pids(output)
      target = child_pids(output).select { |child| alive?(child) }.sample(:random => random)
      signal = %w[TERM INT QUIT].sample(:random => random)
      begin
        Process.kill(signal, target) if target
      rescue Errno::ESRCH
        nil
      end
      sleep random.rand * 0.3
    end
    %w[TERM INT TERM].each { |signal| Process.kill(signal, -pid) rescue nil }
    status, rest = wait_for_launcher(pid, reader, 60)
    output << rest
    seen |= child_pids(output)

    context = "seed #{seed}\n#{output}"
    expect(status).to be_success, context
    keys = ProcessHelpers::Run.pluck(:key)
    expect(keys.tally.values.uniq - [1]).to be_empty, "jobs run twice (#{keys.tally.select { |_, n| n > 1 }}), #{context}"
    left = jobs.map { |j| reload_job(j) }.compact
    expect(left.map(&:locked_by).compact).to be_empty, "jobs left locked, #{context}"
    expect(keys.size + left.size).to eq(60), context
    expect(seen.select { |child| alive?(child) }).to be_empty, "orphaned child processes, #{context}"
  ensure
    reader.close if reader && !reader.closed?
    Process.kill('KILL', -pid) rescue nil
  end

  # R8
  it 'stop when their parent is SIGKILLed while they are still starting up' do
    pid, reader = spawn_launcher(:processes => 2, :startup_delay => 2, :worker => {:sleep_delay => 0.1})
    output = +''
    wait_for(10) { (output << read_available(reader)).scan(/worker \d+ starting up/).size == 2 }
    children = output.scan(/worker (\d+) starting up/).flatten.map(&:to_i)
    Process.kill('KILL', pid)
    Process.wait(pid)
    wait_for(15) { children.none? { |child| alive?(child) } }
    output << read_to_eof(reader, 2)
    expect(output.scan(/Parent process #{pid} is gone; stopping/).size).to eq(2), output
  ensure
    reader.close if reader && !reader.closed?
    (children || []).each { |child| Process.kill('KILL', child) rescue nil }
  end
end
