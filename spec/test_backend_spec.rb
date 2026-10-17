require 'helper'

describe Delayed::Backend::Test::Job do
  it_should_behave_like 'a delayed_job backend'

  describe '.work_off' do
    it 'warns and works off jobs with a new worker' do
      described_class.delete_all
      expect { expect(described_class.work_off).to eq([0, 0]) }.to output(/work_off.*deprecated/).to_stderr
    end
  end

  describe '#error=' do
    it 'skips last_error when the backend has no such column' do
      job = Class.new { include Delayed::Backend::Base }.new
      error = RuntimeError.new('boom')
      job.error = error
      expect(job.error).to be(error)
    end
  end

  describe '#max_run_time' do
    it 'is nil when the payload max_run_time is nil' do
      job = described_class.new
      allow(job).to receive(:payload_object).and_return(double('payload', :max_run_time => nil))
      expect(job.max_run_time).to be_nil
    end
  end

  describe '#set_default_run_at' do
    it 'defaults run_at to now' do
      job = described_class.new
      job.send(:set_default_run_at)
      expect(job.run_at).to be_within(1).of(described_class.db_time_now)
    end

    it 'keeps an existing run_at' do
      run_at = 1.day.from_now
      job = described_class.new(:run_at => run_at)
      job.send(:set_default_run_at)
      expect(job.run_at).to eq(run_at)
    end
  end

  describe '#reload' do
    it 'causes the payload object to be reloaded' do
      job = 'foo'.delay.length
      o = job.payload_object
      expect(o.object_id).not_to eq(job.reload.payload_object.object_id)
    end
  end
end
