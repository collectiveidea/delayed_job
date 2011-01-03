require 'spec_helper'

describe Delayed::Worker do
  describe "backend=" do
    before do
      @clazz = Class.new
      Delayed::Worker.backend = @clazz
    end

    it "should set the Delayed::Job constant to the backend" do
      Delayed::Job.should == @clazz
    end

    it "should set backend with a symbol" do
      Delayed::Worker.backend = :active_record
      Delayed::Worker.backend.should == Delayed::Backend::ActiveRecord::Job
    end
  end

  describe "guess_backend" do
    after do
      Delayed::Worker.backend = :active_record
    end

    it "should set to active_record if nil" do
      Delayed::Worker.backend = nil
      lambda {
        Delayed::Worker.guess_backend
      }.should change { Delayed::Worker.backend }.to(Delayed::Backend::ActiveRecord::Job)
    end

    it "should not override the existing backend" do
      Delayed::Worker.backend = Class.new
      lambda { Delayed::Worker.guess_backend }.should_not change { Delayed::Worker.backend }
    end
  end

  let(:worker) { Delayed::Worker.new }

  describe "#handle_failed_job" do
    it "should log the error message with job data on an error" do
     ActiveRecord::Base.logger.level = 1
     error_job = ErrorJob.new
     error_job.var1 = { :testkey => "testvalue" }
     Delayed::Job.enqueue error_job
     worker.work_off

     job = Delayed::Job.find(:first)

     error_log = File.open("/tmp/dj.log", "r").read
     error_log.should =~ /did not work/
     error_log.should =~ /sample_jobs.rb:15:in `perform'/
     error_log.should =~ /testkey/
     error_log.should =~ /testvalue/
     ActiveRecord::Base.logger.level = 0
    end
  end
end
