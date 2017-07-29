require 'helper'

RSpec.shared_examples_for "a deserialization-safe backend" do
  it "returns an object that responds_to?(:perform)" do
    expect(subject.payload_object).to respond_to(:perform)
  end

  it "does not raise an exception on #payload_object" do
    expect {
      subject.payload_object
    }.to_not raise_error
  end

  it "does not raise an exception on #hook" do
    expect {
      subject.hook(:before)
    }.to_not raise_error
  end

  it "does not raise an exception on #name" do
    expect {
      subject.name
    }.to_not raise_error
  end

  it "does not raise an exception on #reschedule_at" do
    expect {
      subject.reschedule_at
    }.to_not raise_error
  end

  it "does not raise an exception on #max_attempts" do
    expect {
      subject.max_attempts
    }.to_not raise_error
  end

  it "does not raise an exception on #max_run_time" do
    expect {
      subject.max_run_time
    }.to_not raise_error
  end

  it "does not raise an exception on #destroy_failed_jobs?" do
    expect {
      subject.destroy_failed_jobs?
    }.to_not raise_error
  end
end

describe Delayed::Backend::Base, "deserialization" do
  subject { Delayed::Backend::Test::Job.new handler: handler }

  describe "with a valid handler" do
    let(:handler) { "--- !ruby/struct:Autoloaded::Struct {}\n" }

    it_behaves_like "a deserialization-safe backend"
  end

  describe "with YAML that does not parse" do
    let(:handler) { "--- !bad/tag\n" }

    it_behaves_like "a deserialization-safe backend"
  end

  describe "with an ActiveRecord object that is in the database" do
    let(:story)   { Story.create }
    let(:handler) { YAML::dump(story) }

    it_behaves_like "a deserialization-safe backend"
  end

  describe "with an ActiveRecord object that is not in the database" do
    let(:story)   { Story.new.tap {|s| s.story_id = rand(1000) } }
    let(:handler) { YAML::dump(story) }

    it_behaves_like "a deserialization-safe backend"
  end

  describe "with a truncated handler YAML" do
    let(:story)   { Story.create }
    let(:handler) { YAML::dump(story)[0..-10] }

    it_behaves_like "a deserialization-safe backend"
  end
end

describe Delayed::Backend::InvalidPayload do
  subject { described_class.new "handler", NoMethodError.new }

  it "raises a DeserializationError on perform" do
    expect {
      subject.perform
    }.to raise_error(Delayed::DeserializationError)
  end
end
