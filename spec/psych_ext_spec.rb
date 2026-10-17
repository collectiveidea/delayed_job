require 'helper'

describe 'Psych::Visitors::ToRuby', :if => defined?(Psych::Visitors::ToRuby) do
  context BigDecimal do
    it 'deserializes correctly' do
      deserialized = YAML.load_dj("--- !ruby/object:BigDecimal 18:0.1337E2\n...\n")

      expect(deserialized).to be_an_instance_of(BigDecimal)
      expect(deserialized).to eq(BigDecimal('13.37'))
    end
  end

  context 'load_tag handling' do
    # This only broadly works in ruby 2.0 but will cleanly work through load_dj
    # here because this class is so simple it only touches our extention
    YAML.load_tags['!ruby/object:RenamedClass'] = SimpleJob
    # This is how ruby 2.1 and newer works throughout the yaml handling
    YAML.load_tags['!ruby/object:RenamedString'] = 'SimpleJob'

    it 'deserializes class tag' do
      deserialized = YAML.load_dj("--- !ruby/object:RenamedClass\ncheck: 12\n")

      expect(deserialized).to be_an_instance_of(SimpleJob)
      expect(deserialized.instance_variable_get(:@check)).to eq(12)
    end

    it 'deserializes string tag' do
      deserialized = YAML.load_dj("--- !ruby/object:RenamedString\ncheck: 12\n")

      expect(deserialized).to be_an_instance_of(SimpleJob)
      expect(deserialized.instance_variable_get(:@check)).to eq(12)
    end
  end

  it 'returns a falsy value for an empty document' do
    expect(YAML.load_dj('')).to be_falsey
  end

  context 'legacy ActiveRecord tag' do
    it 'loads the record' do
      story = Story.create(:text => 'once upon a time')
      deserialized = YAML.load_dj("--- !ruby/ActiveRecord:Story\nattributes:\n  story_id: #{story.id}\n")
      expect(deserialized).to eq(story)
    end

    it 'raises a DeserializationError when the record is missing' do
      expect { YAML.load_dj("--- !ruby/ActiveRecord:Story\nattributes:\n  story_id: 0\n") }.
        to raise_error(Delayed::DeserializationError, /ActiveRecord::RecordNotFound, class: Story, primary key: 0/)
    end
  end

  context 'Mongoid tag' do
    let(:document) { Object.new }
    let(:model) { double('MongoidModel') }

    before do
      stub_const('Mongoid::Errors::DocumentNotFound', Class.new(StandardError))
      stub_const('MongoidModel', model)
    end

    it 'finds the document by id' do
      allow(model).to receive(:find).with('abc').and_return(document)
      expect(YAML.load_dj("--- !ruby/Mongoid:MongoidModel\nattributes:\n  _id: abc\n")).to be(document)
    end

    it 'raises a DeserializationError when the document is missing' do
      allow(model).to receive(:find).and_raise(Mongoid::Errors::DocumentNotFound, 'gone')
      expect { YAML.load_dj("--- !ruby/Mongoid:MongoidModel\nattributes:\n  _id: abc\n") }.
        to raise_error(Delayed::DeserializationError, /Mongoid::Errors::DocumentNotFound, class: .*, primary key: abc \(gone\)/)
    end
  end

  context 'DataMapper tag' do
    let(:resource) { Object.new }
    let(:key) { double('Property', :key? => true, :name => :id) }
    let(:other) { double('Property', :key? => false, :name => :title) }
    let(:model) { double('DataMapperModel', :properties => [key, other]) }

    before do
      stub_const('DataMapper::ObjectNotFoundError', Class.new(StandardError))
      stub_const('DataMapperModel', model)
    end

    it 'gets the resource by its keys' do
      allow(model).to receive(:get!).with(7).and_return(resource)
      expect(YAML.load_dj("--- !ruby/DataMapper:DataMapperModel\nattributes:\n  id: 7\n")).to be(resource)
    end

    it 'raises a DeserializationError when the resource is missing' do
      allow(model).to receive(:get!).and_raise(DataMapper::ObjectNotFoundError, 'gone')
      expect { YAML.load_dj("--- !ruby/DataMapper:DataMapperModel\nattributes:\n  id: 7\n") }.
        to raise_error(Delayed::DeserializationError, /DataMapper::ObjectNotFoundError, class: .* \(gone\)/)
    end
  end
end
