require 'spec_helper'

describe "YAML" do
  it "should autoload classes" do
    lambda {
      yaml = "--- !ruby/class:Autoloaded::Clazz {}\n"
      YAML.load(yaml).should == Autoloaded::Clazz
    }.should_not raise_error
  end

  it "should autoload the class of a struct" do
    lambda {
      yaml = "--- !ruby/class:Autoloaded::Struct {}\n"
      YAML.load(yaml).should == Autoloaded::Struct
    }.should_not raise_error
  end

  it "should autoload the class for the instance of a struct" do
    lambda {
      yaml = "--- !ruby/struct:Autoloaded::InstanceStruct {}"
      YAML.load(yaml).class.should == Autoloaded::InstanceStruct
    }.should_not raise_error
  end

  it "should autoload the class for the instance" do
    lambda {
      yaml = "--- !ruby/object:Autoloaded::InstanceClazz {}\n"
      YAML.load(yaml).class.should == Autoloaded::InstanceClazz
    }.should_not raise_error
  end

  it "should not throw an uninitialized constant Syck::Syck when using YAML.load_file with poorly formed yaml" do
    lambda {
      YAML.load_file(File.expand_path('spec/fixtures/bad_alias.yml'))
    }.should_not raise_error
  end

  it "should not throw an uninitialized constant Syck::Syck when using YAML.load with poorly formed yaml" do
    lambda { YAML.load(YAML.dump("foo: *bar"))}.should_not raise_error
  end
  
  it 'should preserve and respect original yaml by calling psych init_with after loading ActiveRecord object' do
    lambda {
      class Story < ActiveRecord::Base
        attr_accessor :counter
        
        def init_with(coder)
          super  # Required due to ActiveRecord deficiency
          
          coder['attributes']['text'].should.eql? 'value'
          coder['attributes']['scoped'].should.eql? 't'
          coder['attributes']['story_id'].should.eql? 1
          coder['morestuff'].should.eql? 'xyz'
          
          @counter = @counter.blank? ? 1 : @counter + 1
          self
        end
      end
            
      YAML.parser.class.name.should match(/psych/i)
      s = Story.create(:text => 'value')
      
      y = "--- !ruby/ActiveRecord:Story\nattributes:\n  text: value\n  scoped: true\n  story_id: 1\nmorestuff: xyz"
      s2 = YAML.load(y)
      s2.should_not be_nil
      s2.text.should == 'value'
      s2.scoped.should.eql? 't'
      s2.id.should.eql? 1
      s2.counter.should == 2

    }.should_not raise_error    
    end
  
  it 'should work fine without a psych init_with after loading ActiveRecord object' do
    lambda {
          
      YAML.parser.class.name.should match(/psych/i)
      s = Story.create(:text => 'value')
      
      y = "--- !ruby/ActiveRecord:Story\nattributes:\n  text: value\n  scoped: true\n  story_id: 1"
      s2 = YAML.load(y)
      s2.should_not be_nil
      s2.text.should == 'value'
      s2.scoped.should.eql? 't'
      s2.id.should.eql? 1

    }.should_not raise_error    
    end
end
