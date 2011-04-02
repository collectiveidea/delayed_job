describe ActiveRecord::Base do
  describe "yaml_new" do
    class Story < ActiveRecord::Base
    end

    it "should load YAML representations of records that exist in the database" do
      foo = Story.new
      foo.text = "Hello World"
      foo.save.should == true
      bar = foo.to_yaml
      baz = YAML.load(bar)
      baz.should == foo
    end

    it "should load YAML representation of records that do not exist in the database" do
      foo = Story.new
      foo.text = "Hello World"
      foo.save.should == true
      bar = foo.to_yaml
      puts bar.inspect
      foo.destroy
      baz = YAML.load(bar)
      baz.should == foo
    end

    it "Should load YAML respresentation of a record that has never existed in the database" do
      foo = "--- !ruby/ActiveRecord:Story \nattributes: \n  text: Hello World\n  id: 9001\n"
      bar = YAML.load(foo)
      bar.class.should == Story
      bar.text.should == "Hello World"
      bar.id.should == 9001
    end


  end
end

