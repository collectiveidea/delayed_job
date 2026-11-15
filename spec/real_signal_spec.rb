require 'helper'

# Sends real signals to this process while a dispatcher started with #start
# (its traps installed) runs on the main thread, as in a worker process. The
# other shutdown specs call the trap handlers directly, outside a trap,
# where e.g. locking a Mutex works - inside a real trap it doesn't (CRuby).
describe 'A dispatcher receiving real signals' do
  let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.05) }
  let(:log) { Concurrent::Array.new }

  around do |example|
    signals = %w[TERM INT QUIT].select { |s| Signal.list.key?(s) }
    previous = signals.map { |s| [s, Signal.trap(s, 'DEFAULT')] }
    example.run
  ensure
    previous.each { |s, handler| Signal.trap(s, handler || 'DEFAULT') }
  end

  before do
    skip 'needs to run on the main thread' unless Thread.current == Thread.main
    Delayed::Job.delete_all
    GateJob.reset
    capture_say(log, *and_workers(dispatcher))
  end

  after { GateJob.release = true }

  # Runs the dispatcher here, on the main thread, sending `signal` to this
  # process once the job has started; returns how long the dispatcher took
  # to return after the signal.
  def run_and_signal(signal)
    sent_at = Concurrent::AtomicReference.new
    sender = Thread.new do
      Timeout.timeout(5) { GateJob.started.pop }
      sent_at.set(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      Process.kill(signal, Process.pid)
    end
    Timeout.timeout(15) { dispatcher.start }
    sender.join
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - sent_at.get
  end

  %w[TERM INT].each do |signal|
    it "stops on SIG#{signal}, letting the running job finish" do
      job = Delayed::Job.enqueue(GateJob.new(:a))
      Thread.new do
        sleep 0.5
        GateJob.release = true
      end
      run_and_signal(signal)
      expect(dispatcher).to be_stop
      expect(dispatcher).not_to be_quit
      expect(GateJob.finished).to eq [:a]
      expect(Delayed::Job.all).not_to include(job)
      expect(log.map(&:last)).to include 'Exiting...'
    end
  end

  it 'stops promptly on SIGTERM while idle (the trap wakes the dispatcher)' do
    dispatcher.instance_variable_set(:@quiet, true)
    Delayed::Worker.sleep_delay = 30
    Thread.new do
      sleep 0.3
      Process.kill('TERM', Process.pid)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(10) { dispatcher.start }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3 # Not sleep_delay (30s).
    expect(dispatcher).to be_stop
  end

  it 'quits on SIGQUIT, interrupting and releasing the running job' do
    skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
    skip 'the JVM reserves SIGQUIT' if RUBY_ENGINE == 'jruby'
    job = Delayed::Job.enqueue(GateJob.new(:a))
    took = run_and_signal('QUIT')
    expect(took).to be < 5 # At once, not after the job (which never ends by itself).
    expect(dispatcher).to be_quit
    expect(GateJob.interrupted).to eq [:a]
    job.reload
    expect([job.locked_by, job.locked_at, job.attempts]).to eq [nil, nil, 0]
  end

  it 'interrupts the running job once the shutdown timeout passes after SIGTERM' do
    Delayed::Worker.shutdown_timeout = 0.2
    job = Delayed::Job.enqueue(GateJob.new(:a))
    took = run_and_signal('TERM')
    expect(took).to be_between(0.15, 5)
    expect(GateJob.interrupted).to eq [:a]
    expect(job.reload.locked_by).to be_nil
  end

  context 'with raise_signal_exceptions' do
    before { Delayed::Worker.raise_signal_exceptions = true }
    after { Delayed::Worker.raise_signal_exceptions = false }

    it 'raises SIGTERM out of #start, interrupting the running job' do
      Delayed::Job.enqueue(GateJob.new(:a))
      expect { run_and_signal('TERM') }.to raise_error(SignalException, 'SIGTERM')
      expect(dispatcher).to be_stop
      expect(GateJob.interrupted).to eq [:a]
    end
  end
end
