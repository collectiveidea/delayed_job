require 'spec_helper'
require 'delayed/backend/mongoid'

describe Delayed::Backend::Mongoid::Job do
  before :all do
    Delayed::Worker.backend = :mongoid    
  end
  
  after :all do
    Delayed::Worker.backend = BACKEND
  end
  
  after do
    Time.zone = nil
  end

  it_should_behave_like 'a delayed_job backend'

  context "db_time_now" do
    it "should return time in current time zone if set" do
      Time.zone = 'Eastern Time (US & Canada)'
      %w(EST EDT).should include(Delayed::Job.db_time_now.zone)
    end    
  end

  describe "after_fork" do
    it "should call reconnect on the connection" do
      Mongoid.database.connection.should_receive(:connect)
      Delayed::Backend::Mongoid::Job.after_fork
    end
  end
end