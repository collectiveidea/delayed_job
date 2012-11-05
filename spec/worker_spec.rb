require 'spec_helper'

describe Delayed::Worker do
  describe "backend=" do
    before do
      @clazz = Class.new
      Delayed::Worker.backend = @clazz
    end

    it "sets the Delayed::Job constant to the backend" do
      expect(Delayed::Job).to eq(@clazz)
    end

    it "sets backend with a symbol" do
      Delayed::Worker.backend = :test
      expect(Delayed::Worker.backend).to eq(Delayed::Backend::Test::Job)
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
