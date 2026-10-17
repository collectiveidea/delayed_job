require 'helper'

describe Delayed::Compatibility do
  it 'puts executables in bin' do
    expect(Delayed::Compatibility.executable_prefix).to eq('bin')
  end
end
