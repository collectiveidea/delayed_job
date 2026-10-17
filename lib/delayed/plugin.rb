require 'active_support/core_ext/class/attribute'

module Delayed
  class Plugin
    class_attribute :callback_block # simplecov:disable method - Ruby 4.1 counts readers ActiveSupport replaces

    def self.callbacks(&block)
      self.callback_block = block
    end

    def initialize
      self.class.callback_block.call(Delayed::Worker.lifecycle) if self.class.callback_block
    end
  end
end
