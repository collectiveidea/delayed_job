require 'spec_helper'
require 'delayed/backend/active_record'

describe Delayed::Backend::ActiveRecord::Job do
  after do
    Time.zone = nil
  end

  it_should_behave_like 'a delayed_job backend'

  context "db_time_now" do
    it "should return time in current time zone if set" do
      Time.zone = 'Eastern Time (US & Canada)'
      %w(EST EDT).should include(Delayed::Job.db_time_now.zone)
    end

    it "should return UTC time if that is the AR default" do
      Time.zone = nil
      ActiveRecord::Base.default_timezone = :utc
      Delayed::Backend::ActiveRecord::Job.db_time_now.zone.should == 'UTC'
    end

    it "should return local time if that is the AR default" do
      Time.zone = 'Central Time (US & Canada)'
      ActiveRecord::Base.default_timezone = :local
      %w(CST CDT).should include(Delayed::Backend::ActiveRecord::Job.db_time_now.zone)
    end
  end

  describe "after_fork" do
    it "should call reconnect on the connection" do
      ActiveRecord::Base.should_receive(:establish_connection)
      Delayed::Backend::ActiveRecord::Job.after_fork
    end
  end
  
  describe "enqueue" do
    it "should allow enqueue hook to modify job at DB level" do
      later = described_class.db_time_now + 20.minutes
      job = described_class.enqueue :payload_object => EnqueueJobMod.new
      Delayed::Backend::ActiveRecord::Job.find(job.id).run_at.should be_within(1).of(later)
    end
  end
end
