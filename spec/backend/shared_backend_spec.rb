shared_examples_for 'a backend' do
  def create_job(opts = {})
    @backend.create(opts.merge(:payload_object => SimpleJob.new))
  end

  before do
    Delayed::Worker.max_priority = nil
    Delayed::Worker.min_priority = nil
    Delayed::Worker.default_priority = 99
    SimpleJob.runs = 0
  end
  
  it "should set run_at automatically if not set" do
    @backend.create(:payload_object => ErrorJob.new ).run_at.should_not be_nil
  end

  it "should not set run_at automatically if already set" do
    later = @backend.db_time_now + 5.minutes
    @backend.create(:payload_object => ErrorJob.new, :run_at => later).run_at.should be_close(later, 1)
  end

  it "should raise ArgumentError when handler doesn't respond_to :perform" do
    lambda { @backend.enqueue(Object.new) }.should raise_error(ArgumentError)
  end

  it "should increase count after enqueuing items" do
    @backend.enqueue SimpleJob.new
    @backend.count.should == 1
  end
  
  it "should be able to set priority when enqueuing items" do
    @job = @backend.enqueue SimpleJob.new, 5
    @job.priority.should == 5
  end

  it "should use default priority when it is not set" do
    @job = @backend.enqueue SimpleJob.new
    @job.priority.should == 99
  end

  it "should be able to set run_at when enqueuing items" do
    later = @backend.db_time_now + 5.minutes
    @job = @backend.enqueue SimpleJob.new, 5, later
    @job.run_at.should be_close(later, 1)
  end

  it "should work with jobs in modules" do
    M::ModuleJob.runs = 0
    job = @backend.enqueue M::ModuleJob.new
    lambda { job.invoke_job }.should change { M::ModuleJob.runs }.from(0).to(1)
  end
                   
  it "should raise an DeserializationError when the job class is totally unknown" do
    job = @backend.new :handler => "--- !ruby/object:JobThatDoesNotExist {}"
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end

  it "should raise an DeserializationError when the job is badly encoded" do
    job = @backend.new :handler => "--- !ruby/object:SimpleJob {"
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end

  it "should try to load the class when it is unknown at the time of the deserialization" do
    job = @backend.new :handler => "--- !ruby/object:JobThatDoesNotExist {}"
    job.should_receive(:attempt_to_load).with('JobThatDoesNotExist').and_return(true)
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end

  it "should try include the namespace when loading unknown objects" do
    job = @backend.new :handler => "--- !ruby/object:Delayed::JobThatDoesNotExist {}"
    job.should_receive(:attempt_to_load).with('Delayed::JobThatDoesNotExist').and_return(true)
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end

  it "should also try to load structs when they are unknown (raises TypeError)" do
    job = @backend.new :handler => "--- !ruby/struct:JobThatDoesNotExist {}"
    job.should_receive(:attempt_to_load).with('JobThatDoesNotExist').and_return(true)
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end

  it "should try include the namespace when loading unknown structs" do
    job = @backend.new :handler => "--- !ruby/struct:Delayed::JobThatDoesNotExist {}"
    job.should_receive(:attempt_to_load).with('Delayed::JobThatDoesNotExist').and_return(true)
    lambda { job.payload_object.perform }.should raise_error(Delayed::DeserializationError)
  end
  
  describe "find_available" do
    it "should not find failed jobs" do
      @job = create_job :attempts => 50, :failed_at => @backend.db_time_now
      @backend.find_available('worker', 5, 1.second).should_not include(@job)
    end
    
    it "should not find jobs scheduled for the future" do
      @job = create_job :run_at => (@backend.db_time_now + 1.minute)
      @backend.find_available('worker', 5, 4.hours).should_not include(@job)
    end
    
    it "should not find jobs locked by another worker" do
      @job = create_job(:locked_by => 'other_worker', :locked_at => @backend.db_time_now - 1.minute)
      @backend.find_available('worker', 5, 4.hours).should_not include(@job)
    end
    
    it "should find open jobs" do
      @job = create_job
      @backend.find_available('worker', 5, 4.hours).should include(@job)
    end
    
    it "should find expired jobs" do
      @job = create_job(:locked_by => 'worker', :locked_at => @backend.db_time_now - 2.minutes)
      @backend.find_available('worker', 5, 1.minute).should include(@job)
    end
    
    it "should find own jobs" do
      @job = create_job(:locked_by => 'worker', :locked_at => (@backend.db_time_now - 1.minutes))
      @backend.find_available('worker', 5, 4.hours).should include(@job)
    end

    it "should find only the right amount of jobs" do
      10.times { create_job }
      @backend.find_available('worker', 7, 4.hours).should have(7).jobs
    end
  end
  
  context "when another worker is already performing an task, it" do

    before :each do
      @job = @backend.create :payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => @backend.db_time_now - 5.minutes
    end

    it "should not allow a second worker to get exclusive access" do
      @job.lock_exclusively!(4.hours, 'worker2').should == false
    end

    it "should allow a second worker to get exclusive access if the timeout has passed" do
      @job.lock_exclusively!(1.minute, 'worker2').should == true
    end      
    
    it "should be able to get access to the task if it was started more then max_age ago" do
      @job.locked_at = 5.hours.ago
      @job.save

      @job.lock_exclusively! 4.hours, 'worker2'
      @job.reload
      @job.locked_by.should == 'worker2'
      @job.locked_at.should > 1.minute.ago
    end

    it "should not be found by another worker" do
      @backend.find_available('worker2', 1, 6.minutes).length.should == 0
    end

    it "should be found by another worker if the time has expired" do
      @backend.find_available('worker2', 1, 4.minutes).length.should == 1
    end

    it "should be able to get exclusive access again when the worker name is the same" do
      @job.lock_exclusively!(5.minutes, 'worker1').should be_true
      @job.lock_exclusively!(5.minutes, 'worker1').should be_true
      @job.lock_exclusively!(5.minutes, 'worker1').should be_true
    end                                        
  end
  
  context "when another worker has worked on a task since the job was found to be available, it" do

    before :each do
      @job = @backend.create :payload_object => SimpleJob.new
      @job_copy_for_worker_2 = @backend.find(@job.id)
    end

    it "should not allow a second worker to get exclusive access if already successfully processed by worker1" do
      @job.destroy
      @job_copy_for_worker_2.lock_exclusively!(4.hours, 'worker2').should == false
    end

    it "should not allow a second worker to get exclusive access if failed to be processed by worker1 and run_at time is now in future (due to backing off behaviour)" do
      @job.update_attributes(:attempts => 1, :run_at => 1.day.from_now)
      @job_copy_for_worker_2.lock_exclusively!(4.hours, 'worker2').should == false
    end
  end
  
  describe "reserve" do
    before do
      Delayed::Worker.max_run_time = 2.minutes
      @worker = Delayed::Worker.new(:quiet => true)
    end

    it "should not reserve failed jobs" do
      create_job :attempts => 50, :failed_at => described_class.db_time_now
      described_class.reserve(@worker).should be_nil
    end

    it "should not reserve jobs scheduled for the future" do
      create_job :run_at => (described_class.db_time_now + 1.minute)
      described_class.reserve(@worker).should be_nil
    end

    it "should lock the job so other workers can't reserve it" do
      job = create_job
      described_class.reserve(@worker).should == job
      new_worker = Delayed::Worker.new(:quiet => true)
      new_worker.name = 'worker2'
      described_class.reserve(new_worker).should be_nil
    end

    it "should reserve open jobs" do
      job = create_job
      described_class.reserve(@worker).should == job
    end

    it "should reserve expired jobs" do
      job = create_job(:locked_by => @worker.name, :locked_at => described_class.db_time_now - 3.minutes)
      described_class.reserve(@worker).should == job
    end

    it "should reserve own jobs" do
      job = create_job(:locked_by => @worker.name, :locked_at => (described_class.db_time_now - 1.minutes))
      described_class.reserve(@worker).should == job
    end
  end
  
  context "#name" do
    it "should be the class name of the job that was enqueued" do
      @backend.create(:payload_object => ErrorJob.new ).name.should == 'ErrorJob'
    end

    it "should be the method that will be called if its a performable method object" do
      @job = Story.delay.create
      @job.name.should == "Story.create"
    end

    it "should be the instance method that will be called if its a performable method object" do
      @job = Story.create(:text => "...").delay.save
      @job.name.should == 'Story#save'
    end
  end
  
  context "worker prioritization" do
    before(:each) do
      Delayed::Worker.max_priority = nil
      Delayed::Worker.min_priority = nil
    end

    it "should fetch jobs ordered by priority" do
      10.times { @backend.enqueue SimpleJob.new, rand(10) }
      jobs = @backend.find_available('worker', 10)
      jobs.size.should == 10
      jobs.each_cons(2) do |a, b| 
        a.priority.should <= b.priority
      end
    end

    it "should only find jobs greater than or equal to min priority" do
      min = 5
      Delayed::Worker.min_priority = min
      10.times {|i| @backend.enqueue SimpleJob.new, i }
      jobs = @backend.find_available('worker', 10)
      jobs.each {|job| job.priority.should >= min}
    end

    it "should only find jobs less than or equal to max priority" do
      max = 5
      Delayed::Worker.max_priority = max
      10.times {|i| @backend.enqueue SimpleJob.new, i }
      jobs = @backend.find_available('worker', 10)
      jobs.each {|job| job.priority.should <= max}
    end
  end
  
  context "clear_locks!" do
    before do
      @job = create_job(:locked_by => 'worker', :locked_at => @backend.db_time_now)
    end
    
    it "should clear locks for the given worker" do
      @backend.clear_locks!('worker')
      @backend.find_available('worker2', 5, 1.minute).should include(@job)
    end
    
    it "should not clear locks for other workers" do
      @backend.clear_locks!('worker1')
      @backend.find_available('worker1', 5, 1.minute).should_not include(@job)
    end
  end
  
  context "unlock" do
    before do
      @job = create_job(:locked_by => 'worker', :locked_at => @backend.db_time_now)
    end

    it "should clear locks" do
      @job.unlock
      @job.locked_by.should be_nil
      @job.locked_at.should be_nil
    end
  end
  
  context "large handler" do
    before do
      text = "Lorem ipsum dolor sit amet. " * 1000
      @job = @backend.enqueue Delayed::PerformableMethod.new(text, :length, {})
    end
    
    it "should have an id" do
      @job.id.should_not be_nil
    end
  end
  
  context "max_attempts" do
    before(:each) do
      @job = described_class.enqueue SimpleJob.new
    end
    
    it 'should not be defined' do
      @job.max_attempts.should be_nil
    end
    
    it 'should use the max_retries value on the payload when defined' do
      @job.payload_object.stub!(:max_attempts).and_return(99)
      @job.max_attempts.should == 99
    end 
  end

  describe "worker integration" do
    before do
      @worker = Delayed::Worker.new(:max_priority => nil, :min_priority => nil, :quiet => true)
    end

    describe "running a job" do

      context "when the job raises a deserialization error" do
        it "should mark the job as failed" do
          Delayed::Worker.destroy_failed_jobs = false
          job = described_class.create! :handler => "--- !ruby/object:JobThatDoesNotExist {}"
          @worker.work_off
          job.reload
          job.failed_at.should_not be_nil
        end
      end
    end
  end
end
