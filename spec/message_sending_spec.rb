require 'spec_helper'

describe Delayed::MessageSending do
  describe "handle_asynchronously" do
    class Story
      def tell!(arg);end
      handle_asynchronously :tell!
    end

    it "should alias original method" do
      Story.new.should respond_to(:tell_without_delay!)
      Story.new.should respond_to(:tell_with_delay!)
    end

    it "should create a PerformableMethod" do
      story = Story.create
      lambda {
        job = story.tell!(1)
        job.payload_object.class.should == Delayed::PerformableMethod
        job.payload_object.method_name.should == :tell_without_delay!
        job.payload_object.args.should == [1]
      }.should change { Delayed::Job.count }
    end

    describe 'with options' do
      class Fable
        cattr_accessor :importance
        def tell;end
        handle_asynchronously :tell, :priority => Proc.new { self.importance }
      end

      it 'should set the priority based on the Fable importance' do
        Fable.importance = 10
        job = Fable.new.tell
        job.priority.should == 10

        Fable.importance = 20
        job = Fable.new.tell
        job.priority.should == 20
      end

      describe 'using a proc with parameters' do
        class Yarn
          attr_accessor :importance
          def spin
          end
          handle_asynchronously :spin, :priority => Proc.new {|y| y.importance }
        end

        it 'should set the priority based on the Fable importance' do
          job = Yarn.new.tap {|y| y.importance = 10 }.spin
          job.priority.should == 10

          job = Yarn.new.tap {|y| y.importance = 20 }.spin
          job.priority.should == 20
        end
      end
    end
  end

  context "delay" do
    class FairyTail
      attr_accessor :happy_ending
      def self.princesses;end
      def tell
        @happy_ending = true
      end
    end

    it "should create a new PerformableMethod job" do
      lambda {
        job = "hello".delay.count('l')
        job.payload_object.class.should == Delayed::PerformableMethod
        job.payload_object.method_name.should == :count
        job.payload_object.args.should == ['l']
      }.should change { Delayed::Job.count }.by(1)
    end

    it "should set default priority" do
      Delayed::Worker.default_priority = 99
      job = FairyTail.delay.to_s
      job.priority.should == 99
      Delayed::Worker.default_priority = 0
    end

    it "should set default queue name" do
      Delayed::Worker.default_queue_name = 'abbazabba'
      job = FairyTail.delay.to_s
      job.queue.should == 'abbazabba'
      Delayed::Worker.default_priority = nil
    end

    it "should set job options" do
      run_at = Time.parse('2010-05-03 12:55 AM')
      job = FairyTail.delay(:priority => 20, :run_at => run_at).to_s
      job.run_at.should == run_at
      job.priority.should == 20
    end

    it "should not delay the job when delay_jobs is false" do
      Delayed::Worker.delay_jobs = false
      fairy_tail = FairyTail.new
      lambda {
        lambda {
          fairy_tail.delay.tell
        }.should change(fairy_tail, :happy_ending).from(nil).to(true)
      }.should_not change { Delayed::Job.count }
    end

    it "should delay the job when delay_jobs is true" do
      Delayed::Worker.delay_jobs = true
      fairy_tail = FairyTail.new
      lambda {
        lambda {
          fairy_tail.delay.tell
        }.should_not change(fairy_tail, :happy_ending)
      }.should change { Delayed::Job.count }.by(1)
    end
  end
end
