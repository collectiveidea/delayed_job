require 'helper'

describe 'Delayed::Worker.reset' do
  it 'resets exit_on_complete' do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.reset
    expect(Delayed::Worker.exit_on_complete).to be_nil
  end

  it 'resets min_priority and max_priority' do
    Delayed::Worker.min_priority = 1
    Delayed::Worker.max_priority = 9
    Delayed::Worker.reset
    expect([Delayed::Worker.min_priority, Delayed::Worker.max_priority]).to eq [nil, nil]
  end

  it 'defaults batch_reserve to off, set by Worker.new and reset' do
    expect(Delayed::Worker.batch_reserve).to be false
    Delayed::Worker.new(:batch_reserve => true)
    expect(Delayed::Worker.batch_reserve).to be true
    Delayed::Worker.reset
    expect(Delayed::Worker.batch_reserve).to be false
  end

  it 'resets default_queue_name' do
    Delayed::Worker.default_queue_name = 'mail'
    Delayed::Worker.reset
    expect(Delayed::Worker.default_queue_name).to be_nil
  end

  it 'still resets the other settings' do
    Delayed::Worker.sleep_delay = 1
    Delayed::Worker.queues = %w[mail]
    Delayed::Worker.shutdown_timeout = 3
    Delayed::Worker.silence_logging = true
    Delayed::Worker.reset
    expect(Delayed::Worker.sleep_delay).to eq Delayed::Worker::DEFAULT_SLEEP_DELAY
    expect(Delayed::Worker.queues).to eq []
    expect(Delayed::Worker.shutdown_timeout).to be_nil
    expect(Delayed::Worker.silence_logging).to be false
  end

  it 'leaves settings it never had a default for alone' do
    Delayed::Worker.destroy_failed_jobs = false
    Delayed::Worker.reset
    expect(Delayed::Worker.destroy_failed_jobs).to be false
  ensure
    Delayed::Worker.destroy_failed_jobs = true
  end

  it 'gives jobs enqueued after it no default queue' do
    Delayed::Worker.default_queue_name = 'mail'
    Delayed::Worker.reset
    expect(Delayed::Job.enqueue(SimpleJob.new).queue).to be_nil
  end

  it 'lets a worker process run on after the queue empties' do
    Delayed::Worker.exit_on_complete = true
    Delayed::Worker.reset
    dispatcher = Delayed::Dispatcher.new(:sleep_delay => 0.05)
    allow(dispatcher).to receive(:say)
    thread = Thread.new { dispatcher.run }
    sleep 0.2
    expect(thread).to be_alive
    dispatcher.stop
    Timeout.timeout(5) { thread.join }
  end

  it 'lets Worker.new options set the priorities again' do
    Delayed::Worker.reset
    Delayed::Worker.new(:min_priority => 2, :max_priority => 4)
    expect([Delayed::Worker.min_priority, Delayed::Worker.max_priority]).to eq [2, 4]
  end
end
