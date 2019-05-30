require 'helper'

describe 'Psych::Visitors::ToRuby', :if => defined?(Psych::Visitors::ToRuby) do
  context BigDecimal do
    it 'deserializes correctly' do
      deserialized = YAML.load("--- !ruby/object:BigDecimal 18:0.1337E2\n...\n")

      expect(deserialized).to be_an_instance_of(BigDecimal)
      expect(deserialized).to eq(BigDecimal('13.37'))
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
