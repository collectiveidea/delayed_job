require 'spec_helper'

describe Delayed::Lifecycle do
  let(:lifecycle) { Delayed::Lifecycle.new }
  let(:callback) { lambda {|*args|} }
  let(:arguments) { [1] }
  let(:behavior) { mock(Object, :before! => nil, :after! => nil, :inside! => nil) }
  let(:wrapped_block) { Proc.new { behavior.inside! } }

  describe "before callbacks" do
    before(:each) do
      lifecycle.before(:execute, &callback)
    end

    it "executes before wrapped block" do
      callback.should_receive(:call).with(*arguments).ordered
      behavior.should_receive(:inside!).ordered
      lifecycle.run_callbacks :execute, *arguments, &wrapped_block
    end
  end

  describe "after callbacks" do
    before(:each) do
      lifecycle.after(:execute, &callback)
    end

    it "executes after wrapped block" do
      behavior.should_receive(:inside!).ordered
      callback.should_receive(:call).with(*arguments).ordered
      lifecycle.run_callbacks :execute, *arguments, &wrapped_block
    end
  end

  describe "around callbacks" do
    before(:each) do
      lifecycle.around(:execute) do |*args, &block|
        behavior.before!
        block.call(*args)
        behavior.after!
      end
    end

    it "wraps a block" do
      behavior.should_receive(:before!).ordered
      behavior.should_receive(:inside!).ordered
      behavior.should_receive(:after!).ordered
      lifecycle.run_callbacks :execute, *arguments, &wrapped_block
    end

    it "executes multiple callbacks in order" do
      behavior.should_receive(:one).ordered
      behavior.should_receive(:two).ordered
      behavior.should_receive(:three).ordered

      lifecycle.around(:execute) { |*args, &block| behavior.one; block.call(*args) }
      lifecycle.around(:execute) { |*args, &block| behavior.two; block.call(*args) }
      lifecycle.around(:execute) { |*args, &block| behavior.three; block.call(*args) }

      lifecycle.run_callbacks(:execute, *arguments, &wrapped_block)
    end
  end

  it "raises if callback is executed with wrong number of parameters" do
    lifecycle.before(:execute, &callback)
    expect { lifecycle.run_callbacks(:execute, 1,2,3) {} }.to raise_error(ArgumentError, /1 parameter/)
  end
end
