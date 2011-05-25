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
  
  describe "threaded" do
    after do
      Delayed::Worker.threaded = false
    end
    it "should default to none threaded worker" do
      Delayed::Worker.threaded.should == false
    end
    it "Rails initializer should control ability to thread" do
      Delayed::Worker.threaded = true
      Delayed::Worker.threaded.should == true
    end
    it "should control ability to fork" do
      Delayed::Worker.new(:threaded=>true).cant_fork.should_not == true &&
      Delayed::Worker.new(:threaded=>false).cant_fork.should == true
    end
  end
end
