# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'delayed/serialization/active_record'

describe "active_record" do
  ActiveRecord::Schema.define do
    create_table :active_record_test_classes, :force => true do |t|
      t.column :name, :string
    end

    create_table :active_record_composite_test_classes, :force => true, :id => false do |t|
      t.column :key1, :string
      t.column :key2, :string
      t.column :name, :string
    end
  end

  class ActiveRecordTestClass < ActiveRecord::Base
  end

  class ActiveRecordCompositeTestClass < ActiveRecord::Base
  end

  describe "when the model has a single primary key" do
    subject { ActiveRecordTestClass.create(:name => "joe") }
    it "should load the right instance according to the attributes list" do
      instance = ActiveRecord::Base.yaml_new(ActiveRecordTestClass, nil, {'attributes' => {'id' => subject.id}})
      expect(instance).to eq(subject)
    end
  end

  # implementation which takes composite primary keys into account
  describe "when the model has multiple primary keys" do
    subject{ ActiveRecordCompositeTestClass.create(:key1 => "pink", :key2 => "floyd", :name => "joe")}
    before(:each) do
      subject

    end
    it "should load the right instances according to the attributes list" do
      finder = mock(:finder)
      finder.should_receive(:find).with('pink', 'floyd').and_return(subject)
      ActiveRecordCompositeTestClass.stub! :primary_key => ["key1", "key2"], :unscoped => finder
      instance = ActiveRecord::Base.yaml_new(ActiveRecordCompositeTestClass, nil, {'attributes' => {'key1' => subject.key1, 'key2' => subject.key2}})
      expect(instance).to eq(subject)
    end
  end
end