require 'helper'

describe Delayed::Inbox do
  let(:inbox) { described_class.new }
  let(:now) { Time.now }

  def job(priority, run_at = now)
    Delayed::Job.new(:priority => priority, :run_at => run_at)
  end

  it 'pops the lowest priority first, then the earliest run_at, then the first handed over' do
    late = job(0, now)
    early = job(0, now - 60)
    urgent = job(-5, now)
    same1 = job(3)
    same2 = job(3)
    [late, same1, urgent, same2, early].each { |j| inbox.push(:slot, j, 0) }
    expect(Array.new(5) { inbox.pop[1] }).to eq [urgent, early, late, same1, same2]
  end

  it 'returns the slot and when the job was reserved' do
    j = job(0)
    inbox.push(:slot0, j, 12.5)
    expect(inbox.pop).to eq [:slot0, j, 12.5]
  end

  it 'waits for a job' do
    j = job(0)
    popped = Thread.new { inbox.pop }
    sleep 0.05
    expect(popped).to be_alive
    inbox.push(:slot, j, 0)
    expect(Timeout.timeout(5) { popped.value }[1]).to eq j
  end

  it 'returns EOQ once closed and empty, after the jobs left' do
    j = job(0)
    inbox.push(:slot, j, 0)
    inbox.close
    expect(inbox.pop[1]).to eq j
    expect(inbox.pop).to equal described_class::EOQ
  end

  it 'wakes a waiting pop when closed' do
    popped = Thread.new { inbox.pop }
    sleep 0.05
    inbox.close
    expect(Timeout.timeout(5) { popped.value }).to equal described_class::EOQ
  end

  it 'drains every job without waiting' do
    jobs = [job(1), job(0)]
    jobs.each { |j| inbox.push(:slot, j, 0) }
    expect(inbox.drain.map { |_, j| j }).to eq jobs
    expect(inbox.size).to eq 0
  end

  it 'orders jobs without run_at first' do
    unscheduled = job(0, nil)
    inbox.push(:slot, job(0), 0)
    inbox.push(:slot, unscheduled, 0)
    expect(inbox.pop[1]).to eq unscheduled
  end
end
