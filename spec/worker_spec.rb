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
  
  describe "running a job" do
    before(:each) do
      @worker = Delayed::Worker.new
    end
    
    after(:each) do 
      Delayed::Job.delete_all
    end
    
    describe 'that fails' do
      before(:each) do
        @handler = ErrorJob.new
        @job = Delayed::Job.enqueue(@handler)
      end
      
      it 'should increase the attempts' do
        @worker.run(@job)
        @job.attempts.should == 1
      end
      
      it 'should reschedule the job in the future' do 
        @worker.run(@job) 
        @job.run_at.should > Job.db_time_now + 5
      end

      describe 'with custom rescheduling strategy' do
        before(:each) do
          @reschedule_at = Time.current + 7.hours
          @handler.stub!(:reschedule_at).and_return(@reschedule_at)
        end
        
        it 'should invoke the strategy' do
          @handler.should_receive(:reschedule_at) do |time, attempts|
            (Job.db_time_now - time).should < 2
            attempts.should == 1
            
            Job.db_time.now + 5
          end

          @worker.run(@job)
        end
        
      end
      
      it 'should reschedule at the specified time' do        
        @worker.run(@job)
        @job.run_at.should == @reschedule_at
      end
    end
  end
end
