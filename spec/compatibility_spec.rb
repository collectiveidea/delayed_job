require 'helper'

describe Delayed::Compatibility do
  it 'puts executables in bin on Rails 4 and later, and in script before' do
    expected = ActiveSupport::VERSION::MAJOR >= 4 ? 'bin' : 'script'
    expect(Delayed::Compatibility.executable_prefix).to eq(expected)
  end
end
