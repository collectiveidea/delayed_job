require 'spec_helper'

describe YAML do
  it "should autoload classes that are unknown at runtime" do
    lambda {
      YAML.load("--- !ruby/object:Autoloaded::Clazz {}")
    }.should_not raise_error
  end

  it "should autoload structs that are unknown at runtime" do
    lambda {
      YAML.load("--- !ruby/struct:Autoloaded::Struct {}")
    }.should_not raise_error
  end

end