require 'helper'

describe 'Psych::Visitors::ToRuby', :if => defined?(Psych::Visitors::ToRuby) do
  context BigDecimal do
    it 'deserializes correctly' do
      deserialized = YAML.load("--- !ruby/object:BigDecimal 18:0.1337E2\n...\n")

      expect(deserialized).to be_an_instance_of(BigDecimal)
      expect(deserialized).to eq(BigDecimal('13.37'))
    end
  end

  context 'errors' do
    it 'raises a DeserializationError' do
      yaml = <<-YAML
--- !ruby/marshalable:Delegator
  :__v2__:
YAML
      expect { Psych.load_dj(yaml) }.to raise_error Delayed::DeserializationError
    end
  end
end
