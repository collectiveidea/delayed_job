require 'spec_helper'

describe Delayed::Worker do
  def job_create(opts = {})
    Delayed::Job.create(opts.merge(:payload_object => SimpleJob.new))
  end

  describe "backend=" do
    it "should set the Delayed::Job constant to the backend" do
      @clazz = Class.new
      Delayed::Worker.backend = @clazz
      Delayed::Job.should == @clazz
    end
    
    it "should set backend with a symbol" do
      Delayed::Worker.backend = Class.new
      Delayed::Worker.backend = :active_record
      Delayed::Worker.backend.should == Delayed::Backend::ActiveRecord::Job
    end
  end
  
  BACKENDS.each do |backend|
    describe "with the #{backend} backend" do
      before do
        Delayed::Worker.backend = backend
        Delayed::Job.delete_all

        @worker = Delayed::Worker.new(:max_priority => nil, :min_priority => nil, :quiet => true)

        SimpleJob.runs = 0
      end
  
      describe "running a job" do
        it "should fail after Worker.max_run_time" do
          begin
            old_max_run_time = Delayed::Worker.max_run_time
            Delayed::Worker.max_run_time = 1.second
            @job = Delayed::Job.create :payload_object => LongRunningJob.new
            @worker.run(@job)
            @job.reload.last_error.should =~ /expired/
            @job.attempts.should == 1
          ensure
            Delayed::Worker.max_run_time = old_max_run_time
          end
        end
      end
  
      context "worker prioritization" do
        before(:each) do
          @worker = Delayed::Worker.new(:max_priority => 5, :min_priority => -5, :quiet => true)
        end

        it "should only work_off jobs that are >= min_priority" do
          SimpleJob.runs.should == 0

          job_create(:priority => -10)
          job_create(:priority => 0)
          @worker.work_off

          SimpleJob.runs.should == 1
        end

        it "should only work_off jobs that are <= max_priority" do
          SimpleJob.runs.should == 0

          job_create(:priority => 10)
          job_create(:priority => 0)

          @worker.work_off

          SimpleJob.runs.should == 1
        end
      end

      context "while running with locked and expired jobs" do
        before(:each) do
          @worker.name = 'worker1'
        end
    
        it "should not run jobs locked by another worker" do
          job_create(:locked_by => 'other_worker', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
          lambda { @worker.work_off }.should_not change { SimpleJob.runs }
        end
    
        it "should run open jobs" do
          job_create
          lambda { @worker.work_off }.should change { SimpleJob.runs }.from(0).to(1)
        end
    
        it "should run expired jobs" do
          expired_time = Delayed::Job.db_time_now - (1.minutes + Delayed::Worker.max_run_time)
          job_create(:locked_by => 'other_worker', :locked_at => expired_time)
          lambda { @worker.work_off }.should change { SimpleJob.runs }.from(0).to(1)
        end
    
        it "should run own jobs" do
          job_create(:locked_by => @worker.name, :locked_at => (Delayed::Job.db_time_now - 1.minutes))
          lambda { @worker.work_off }.should change { SimpleJob.runs }.from(0).to(1)
        end
      end
  
      describe "failed jobs" do
        before do
          # reset defaults
          Delayed::Worker.destroy_failed_jobs = true
          Delayed::Worker.max_attempts = 25
          Delayed::Job.delete_all

          @job = Delayed::Job.enqueue ErrorJob.new
        end

        it "should record last_error when destroy_failed_jobs = false, max_attempts = 1" do
          Delayed::Worker.destroy_failed_jobs = false
          Delayed::Worker.max_attempts = 1
          @worker.run(@job)
          @job.reload
          @job.last_error.should =~ /did not work/
          @job.last_error.should =~ /worker_spec.rb/
          @job.attempts.should == 1
          @job.failed_at.should_not be_nil
        end
    
        it "should re-schedule jobs after failing" do
          @worker.work_off
          @job.reload
          @job.last_error.should =~ /did not work/
          @job.last_error.should =~ /sample_jobs.rb:8:in `perform'/
          @job.attempts.should == 1
          @job.run_at.should > Delayed::Job.db_time_now - 10.minutes
          @job.run_at.should < Delayed::Job.db_time_now + 10.minutes
          @job.locked_at.should be_nil
          @job.locked_by.should be_nil
        end
        
        context "when the job's payload implements #reschedule_at" do
          before(:each) do
            @reschedule_at = Time.current + 7.hours
            @job.payload_object.stub!(:reschedule_at).and_return(@reschedule_at)
          end

          it 'should invoke the strategy to re-schedule' do
            @job.payload_object.should_receive(:reschedule_at) do |time, attempts|
              (Delayed::Job.db_time_now - time).should < 2
              attempts.should == 1

              Delayed::Job.db_time_now + 5
            end

            @worker.run(@job)
          end
        end
      end
  
      context "reschedule" do
        before do
          @job = Delayed::Job.create :payload_object => SimpleJob.new
        end
   
        share_examples_for "any failure more than Worker.max_attempts times" do
          context "when the job's payload has an #on_permanent_failure hook" do
            before do
              @job = Delayed::Job.create :payload_object => OnPermanentFailureJob.new
              @job.payload_object.should respond_to :on_permanent_failure
            end

            it "should run that hook" do
              @job.payload_object.should_receive :on_permanent_failure
              @worker.reschedule(@job)
            end
          end

          context "when the job's payload has no #on_permanent_failure hook" do
            # It's a little tricky to test this in a straightforward way, 
            # because putting a should_not_receive expectation on 
            # @job.payload_object.on_permanent_failure makes that object
            # incorrectly return true to 
            # payload_object.respond_to? :on_permanent_failure, which is what
            # reschedule uses to decide whether to call on_permanent_failure.  
            # So instead, we just make sure that the payload_object as it 
            # already stands doesn't respond_to? on_permanent_failure, then
            # shove it through the iterated reschedule loop and make sure we
            # don't get a NoMethodError (caused by calling that nonexistent
            # on_permanent_failure method).
            
            before do
              @job.payload_object.should_not respond_to(:on_permanent_failure)
            end

            it "should not try to run that hook" do
              lambda do
                Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
              end.should_not raise_exception(NoMethodError)
            end
          end
        end

        context "and we want to destroy jobs" do
          before do
            Delayed::Worker.destroy_failed_jobs = true
          end

          it_should_behave_like "any failure more than Worker.max_attempts times"

          it "should be destroyed if it failed more than Worker.max_attempts times" do
            @job.should_receive(:destroy)
            Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
          end
      
          it "should not be destroyed if failed fewer than Worker.max_attempts times" do
            @job.should_not_receive(:destroy)
            (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(@job) }
          end
        end
    
        context "and we don't want to destroy jobs" do
          before do
            Delayed::Worker.destroy_failed_jobs = false
          end
      
          it_should_behave_like "any failure more than Worker.max_attempts times"

          it "should be failed if it failed more than Worker.max_attempts times" do
            @job.reload.failed_at.should == nil
            Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
            @job.reload.failed_at.should_not == nil
          end

          it "should not be failed if it failed fewer than Worker.max_attempts times" do
            (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(@job) }
            @job.reload.failed_at.should == nil
          end
        end
      end

      context "auto scaling, it" do
        before do
          Delayed::Worker.stub!(:auto_scale).and_return(true)
          @manager = mock('sample manager', :qty => 0)
          Delayed::Manager.stub!(:instance).and_return(@manager)
        end

        it "doesn't spin a worker if auto_scale = false" do
          Delayed::Worker.stub!(:auto_scale).and_return(false)
          @manager.should_not_receive(:scale_up)
          Delayed::Job.create(:payload_object => SimpleJob.new)
        end

        it "doesn't spin a worker if there's one or more working already" do
          @manager.stub!(:qty).and_return(2)
          @manager.should_not_receive(:scale_up)
          Delayed::Job.create(:payload_object => SimpleJob.new)
        end

        it "spins a worker otherwise" do
          @manager.should_receive(:scale_up)
          Delayed::Job.create(:payload_object => SimpleJob.new)
        end
      end

    end
  end
  
end
