require 'helper'

# With Worker.exit_on_complete, a dispatcher exits once a poll finds no job
# and no job is running. A job that enqueues another as it finishes must not
# make it exit with that job left behind.
describe 'Exiting on complete, with jobs that enqueue jobs' do
  before do
    Delayed::Job.delete_all
    ChainJob.runs = Concurrent::Array.new
    Delayed::Worker.exit_on_complete = true
  end

  after { ChainJob.fixed_sleep = nil }

  def dispatcher(threads)
    Delayed::Dispatcher.new(:threads => threads, :sleep_delay => 0.05).tap { |d| allow(d).to receive(:say) }
  end

  it 'polls again when a job finished during a poll that found nothing' do
    d = dispatcher(2)
    ChainJob.fixed_sleep = 0.3 # Still running when the next poll (after sleep_delay) starts.
    polls = 0
    allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, *args|
      polls += 1
      next m.call(*args) unless polls == 2
      # This poll's query ran before the first link enqueued the second;
      # the first link then finishes while the poll is still under way.
      wait_until(5) { ChainJob.runs.size == 1 }
      sleep 0.05 # Let its worker thread record that it finished.
      []
    end
    Delayed::Job.enqueue(ChainJob.new(1, 0, 2, 0))
    Timeout.timeout(10) { d.run }
    expect(ChainJob.runs).to eq [[1, 0], [1, 1]]
    expect(Delayed::Job.count).to eq 0
  end

  it 'still exits when nothing finished during the poll' do
    d = dispatcher(2)
    Timeout.timeout(5) { d.run }
    expect(Delayed::Job.count).to eq 0
  end

  [1, 2, 4].each do |threads|
    it "runs every link of concurrent job chains with #{threads} thread(s), whatever the timing" do
      seed = Random.new_seed
      srand(seed)
      25.times do |round|
        ChainJob.runs = Concurrent::Array.new
        chains = Array.new(3) { |c| [c, rand(2..6)] }
        chains.each { |c, length| Delayed::Job.enqueue(ChainJob.new(c, 0, length, 0.01)) }
        Timeout.timeout(20) { dispatcher(threads).run }
        expected = chains.flat_map { |c, length| Array.new(length) { |link| [c, link] } }
        expect(ChainJob.runs).to match_array(expected), "round #{round}, seed #{seed}: ran #{ChainJob.runs.sort}"
        expect(Delayed::Job.count).to eq(0), "round #{round}, seed #{seed}"
      end
    end
  end
end
