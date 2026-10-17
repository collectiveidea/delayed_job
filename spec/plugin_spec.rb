require 'helper'

describe Delayed::Plugin do
  it 'does nothing without callbacks' do
    plugin = Class.new(Delayed::Plugin)
    expect(plugin.callback_block?).to be false
    expect(plugin.new.callback_block).to be_nil
  end

  it 'runs its callbacks against the worker lifecycle' do
    lifecycles = []
    plugin = Class.new(Delayed::Plugin) do
      callbacks { |lifecycle| lifecycles << lifecycle }
    end

    instance = plugin.new
    expect(lifecycles).to eq([Delayed::Worker.lifecycle])
    expect(instance.callback_block?).to be true
  end
end
