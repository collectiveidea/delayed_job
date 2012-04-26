require 'spec_helper'

describe Delayed::PerformableMethod do
  describe "perform" do
    before do
      @method = Delayed::PerformableMethod.new("foo", :count, ['o'])
    end

    context "with the persisted record cannot be found" do
      before do
        @method.object = nil
      end

      it "should be a no-op if object is nil" do
        lambda { @method.perform }.should_not raise_error
      end
    end

    it "should call the method on the object" do
      @method.object.should_receive(:count).with('o')
      @method.perform
    end
  end

  describe "permit_unpersisted" do
    before do
      @story = Story.create
      @story.story_id = nil
    end

    after do
      Delayed::PerformableMethod.permit_unpersisted = false
    end

    context "with permit_unpersisted" do
      it "should not raise ArgumentError" do
        Delayed::PerformableMethod.permit_unpersisted = true

        lambda {
          @story.delay.tell
        }.should_not raise_error(ArgumentError)
      end
    end

    context "without permit_unpersisted" do
      it "should raise ArgumentError" do 
        lambda {
          @story.delay.tell
        }.should raise_error(ArgumentError, "Jobs cannot be created for records before they've been persisted")
      end
    end
  end

  it "should raise a NoMethodError if target method doesn't exist" do
    lambda {
      Delayed::PerformableMethod.new(Object, :method_that_does_not_exist, [])
    }.should raise_error(NoMethodError)
  end

  it "should not raise NoMethodError if target method is private" do
    clazz = Class.new do
      def private_method
      end
      private :private_method
    end
    lambda {
      Delayed::PerformableMethod.new(clazz.new, :private_method, [])
    }.should_not raise_error(NoMethodError)
  end

  describe "hooks" do
    %w(enqueue before after success).each do |hook|
      it "should delegate #{hook} hook to object" do
        story = Story.create
        story.should_receive(hook).with(an_instance_of(Delayed::Job))
        story.delay.tell.invoke_job
      end
    end

    %w(before after success).each do |hook|
      it "should delegate #{hook} hook to object when delay_jobs = false" do
        Delayed::Worker.delay_jobs = false
        story = Story.create
        story.should_receive(hook).with(an_instance_of(Delayed::Job))
        story.delay.tell
      end
    end

    it "should delegate error hook to object" do
      story = Story.create
      story.should_receive(:error).with(an_instance_of(Delayed::Job), an_instance_of(RuntimeError))
      story.should_receive(:tell).and_raise(RuntimeError)
      lambda { story.delay.tell.invoke_job }.should raise_error
    end

    it "should delegate error hook to object when delay_jobs = false" do
      Delayed::Worker.delay_jobs = false
      story = Story.create
      story.should_receive(:error).with(an_instance_of(Delayed::Job), an_instance_of(RuntimeError))
      story.should_receive(:tell).and_raise(RuntimeError)
      lambda { story.delay.tell }.should raise_error
    end

    it "should delegate failure hook to object" do
      method = Delayed::PerformableMethod.new("object", :size, [])
      method.object.should_receive(:failure)
      method.failure
    end

    it "should delegate failure hook to object when delay_jobs = false" do
      Delayed::Worker.delay_jobs = false
      method = Delayed::PerformableMethod.new("object", :size, [])
      method.object.should_receive(:failure)
      method.failure
    end

  end
end
