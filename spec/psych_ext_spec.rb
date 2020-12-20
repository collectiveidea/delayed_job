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

  context 'with a old reference' do
    class NewKlass; end

    let(:klass) { NewKlass.name }
    let(:invalid_reference) { 'OldKlass' }
    let(:invalid_yaml) { "--- !ruby/class '#{invalid_reference}'\n" }

    it 'raise an error when is not refered' do
      expect { YAML.load(invalid_yaml) }.to raise_error ArgumentError
    end

    it 'deserializes correctly when is refered' do
      expect do
        Psych.old_class_references = {invalid_reference => klass}
        expect(YAML.load(invalid_yaml)).to be Kernel.const_get(klass)
        Psych.old_class_references = {}
      end.not_to raise_error
    end
  end
end
