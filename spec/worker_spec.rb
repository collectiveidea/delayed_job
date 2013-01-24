require 'spec_helper'

describe Delayed::Worker do
  describe "backend=" do
    before do
      @clazz = Class.new
      Delayed::Worker.backend = @clazz
    end

    after do
      Delayed::Worker.backend = :test
    end

    it "sets the Delayed::Job constant to the backend" do
      expect(Delayed::Job).to eq(@clazz)
    end

    it "sets backend with a symbol" do
      Delayed::Worker.backend = :test
      expect(Delayed::Worker.backend).to eq(Delayed::Backend::Test::Job)
    end
  end

  context "worker read-ahead" do
    before do
      @read_ahead = Delayed::Worker.read_ahead
    end

    after do
      Delayed::Worker.read_ahead = @read_ahead
    end

    it "reads five jobs" do
      Delayed::Job.should_receive(:find_available).with(anything, 5, anything).and_return([])
      Delayed::Job.reserve(Delayed::Worker.new)
    end

    it "reads a configurable number of jobs" do
      Delayed::Worker.read_ahead = 15
      Delayed::Job.should_receive(:find_available).with(anything, Delayed::Worker.read_ahead, anything).and_return([])
      Delayed::Job.reserve(Delayed::Worker.new)
    end
  end

  context "worker exit on complete" do
    before do
      Delayed::Worker.exit_on_complete = true
    end

    after do
      Delayed::Worker.exit_on_complete = false
    end

    it "exits the loop when no jobs are available" do
      worker = Delayed::Worker.new
      Timeout::timeout(2) do
        worker.start
      end
    end
  end
end
