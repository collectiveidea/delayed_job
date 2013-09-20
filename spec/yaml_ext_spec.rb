require 'helper'

describe "YAML" do
  it "autoloads classes" do
    expect {
      yaml = "--- !ruby/class Autoloaded::Clazz\n"
      expect(load_with_delayed_visitor(yaml)).to eq(Autoloaded::Clazz)
    }.not_to raise_error
  end

  it "autoloads the class of a struct" do
    expect {
      yaml = "--- !ruby/class Autoloaded::Struct\n"
      expect(load_with_delayed_visitor(yaml)).to eq(Autoloaded::Struct)
    }.not_to raise_error
  end

  it "autoloads the class for the instance of a struct" do
    expect {
      yaml = "--- !ruby/struct:Autoloaded::InstanceStruct {}"
      expect(load_with_delayed_visitor(yaml).class).to eq(Autoloaded::InstanceStruct)
    }.not_to raise_error
  end

  it "autoloads the class for the instance" do
    expect {
      yaml = "--- !ruby/object:Autoloaded::InstanceClazz {}\n"
      expect(load_with_delayed_visitor(yaml).class).to eq(Autoloaded::InstanceClazz)
    }.not_to raise_error
  end

  it "does not throw an uninitialized constant Syck::Syck when using YAML.load with poorly formed yaml" do
    expect{ YAML.load(YAML.dump("foo: *bar"))}.not_to raise_error
  end

  def load_with_delayed_visitor(yaml)
    YAML.load(yaml, nil, Delayed::PsychExt::ToRuby)
  end
end
