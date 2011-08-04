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

  describe 'failed' do
    before do
      @worker = Delayed::Worker.new
      @job = Delayed::Job.new
      @job.should_receive(:hook).with(:failure) {raise 'failure callback raised'}
    end
    it 'should trap exceptions' do
      expect {@worker.failed(@job)}.to_not raise_error
    end
  end
end
