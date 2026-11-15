require 'helper'

describe 'The process title of a worker process' do
  let(:dispatcher) { Delayed::Dispatcher.new(:threads => 3, :sleep_delay => 0.02, :procline => 'delayed_job.0') }
  let(:titles) { Queue.new }

  around do |example|
    original = $0
    example.run
  ensure
    $0 = original
  end

  before do
    Delayed::Job.delete_all
    BlockingJob.reset
    silence_say(*and_workers(dispatcher))
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(nil))
  end

  after do
    BlockingJob.release = true
    Delayed::Worker.reset
  end

  def wait_for_title(expected)
    wait_until(5) { $0 == expected }
    $0
  end

  describe '#procline' do
    it 'shows the busy threads and the queues' do
      expect(dispatcher.procline).to eq 'delayed_job.0: 0/3 busy, queues=*'
      Delayed::Worker.queues = %w[mail sms]
      expect(dispatcher.procline).to eq 'delayed_job.0: 0/3 busy, queues=mail,sms'
    end

    it 'shows that it is stopping' do
      dispatcher.stop
      expect(dispatcher.procline).to eq 'delayed_job.0: stopping, 0/3 busy, queues=*'
    end

    it 'shows that it is quitting' do
      dispatcher.quit
      expect(dispatcher.procline).to eq 'delayed_job.0: quitting, 0/3 busy, queues=*'
    end
  end

  it 'is updated as jobs start and finish' do
    thread = run_in_thread
    wait_for_title('delayed_job.0: 0/3 busy, queues=*')

    2.times { Delayed::Job.enqueue(BlockingJob.new) }
    Timeout.timeout(5) { 2.times { BlockingJob.started.pop } }
    wait_for_title('delayed_job.0: 2/3 busy, queues=*')

    BlockingJob.release = true
    wait_for_title('delayed_job.0: 0/3 busy, queues=*')
    dispatcher.stop
    Timeout.timeout(5) { thread.join }
  end

  it 'shows that it is stopping while running jobs finish' do
    Delayed::Job.enqueue(BlockingJob.new)
    thread = run_in_thread
    Timeout.timeout(5) { BlockingJob.started.pop }
    dispatcher.stop
    wait_for_title('delayed_job.0: stopping, 1/3 busy, queues=*')
    BlockingJob.release = true
    Timeout.timeout(5) { thread.join }
    expect($0).to eq 'delayed_job.0: stopping, 0/3 busy, queues=*'
  end

  it 'is left alone without the :procline option' do
    $0 = 'my process'
    plain = Delayed::Dispatcher.new(:threads => 2)
    allow(plain).to receive(:say)
    Delayed::Job.enqueue(SimpleJob.new)
    Delayed::Worker.exit_on_complete = true
    Timeout.timeout(5) { plain.run }
    expect($0).to eq 'my process'
  end

  it 'is not set by Worker#work_off' do
    $0 = 'my process'
    Delayed::Job.enqueue(SimpleJob.new)
    Delayed::Worker.new.work_off
    expect($0).to eq 'my process'
  end

  it 'is only set when it changes' do
    written = []
    allow(dispatcher).to receive(:update_procline).and_wrap_original do |m|
      before = dispatcher.instance_variable_get(:@procline_title)
      m.call
      after = dispatcher.instance_variable_get(:@procline_title)
      written << after unless after == before
    end
    Delayed::Job.enqueue(SimpleJob.new)
    Delayed::Worker.exit_on_complete = true
    Timeout.timeout(5) { dispatcher.run }
    expect(dispatcher).to have_received(:update_procline).at_least(3).times
    expect(written.first).to eq 'delayed_job.0: 0/3 busy, queues=*'
    expect(written.each_cons(2).none? { |a, b| a == b }).to be true
    expect($0).to eq written.last
  end

  describe 'launchers' do
    it 'name a forked worker process after the worker, with the prefix' do
      launcher = Delayed::Launcher::Forking.new(:prefix => 'app')
      allow(Delayed::Worker).to receive(:after_fork)
      allow(Dir).to receive(:chdir)
      expect(Delayed::Dispatcher).to receive(:new).with(hash_including(:procline => 'app/delayed_job.1')).and_return(double(:name_prefix= => nil, :start => nil, :cleanly_stopped? => true))
      launcher.send(:run_worker, 'delayed_job.1', {})
    end

    it 'name a single worker process' do
      launcher = Delayed::Launcher::Forking.new(:identifier => 2)
      allow(launcher).to receive(:setup_logger)
      allow(launcher).to receive(:trap_signals)
      expect(Delayed::Dispatcher).to receive(:new).with(hash_including(:procline => 'delayed_job.2')).and_return(double(:start => nil))
      launcher.launch
    end
  end
end
