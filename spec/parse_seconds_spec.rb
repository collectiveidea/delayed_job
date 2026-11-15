require 'helper'

describe 'Delayed.parse_seconds' do
  it 'parses whole seconds as an Integer' do
    expect(Delayed.parse_seconds('5')).to eql 5
    expect(Delayed.parse_seconds('0')).to eql 0
  end

  it 'parses fractional seconds as a Float' do
    expect(Delayed.parse_seconds('0.5')).to eql 0.5
    expect(Delayed.parse_seconds('2.25')).to eql 2.25
  end

  it 'reads leading zeros as decimal, not octal' do
    expect(Delayed.parse_seconds('010')).to eql 10
    expect(Delayed.parse_seconds('08')).to eql 8
  end

  it 'parses negative numbers, for validation to reject with its own message' do
    expect(Delayed.parse_seconds('-1')).to eql(-1)
    expect(Delayed.parse_seconds('-0.5')).to eql(-0.5)
  end

  it 'ignores surrounding whitespace' do
    expect(Delayed.parse_seconds(" 30\n")).to eql 30
  end

  it 'accepts numbers' do
    expect(Delayed.parse_seconds(7)).to eql 7
  end

  ['0x10', '1_0', '1e2', '1.', '.5', '+5', '5s', 'soon', '', ' ', nil].each do |value|
    it "rejects #{value.inspect}" do
      expect { Delayed.parse_seconds(value) }.to raise_error(ArgumentError, "invalid number of seconds: #{value.inspect}")
    end
  end
end

describe 'Delayed.check_trappable!' do
  it 'refuses QUIT on the JVM only, without trapping it (which would print a JVM warning)' do
    stub_const('RUBY_ENGINE', 'jruby')
    expect { Delayed.check_trappable!('QUIT') }.to raise_error(ArgumentError, "can't trap reserved signal: SIGQUIT")
    expect { Delayed.check_trappable!('TERM') }.not_to raise_error
    stub_const('RUBY_ENGINE', 'ruby')
    expect { Delayed.check_trappable!('QUIT') }.not_to raise_error
  end
end
