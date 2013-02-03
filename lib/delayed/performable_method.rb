require 'active_support/core_ext/module/delegation'

module Delayed
  class PerformableMethod
    cattr_accessor :permit_unpersisted
    attr_accessor :object, :method_name, :args

    delegate :method, :to => :object

    def initialize(object, method_name, args)
      raise NoMethodError, "undefined method `#{method_name}' for #{object.inspect}" unless object.respond_to?(method_name, true)

      if !Delayed::PerformableMethod.permit_unpersisted && object.respond_to?(:new_record?) && object.new_record?
        raise(ArgumentError, 'Jobs cannot be created for records before they\'ve been persisted')
      end

      self.object       = object
      self.args         = args
      self.method_name  = method_name.to_sym
    end

    def display_name
      "#{object.class}##{method_name}"
    end

    def perform
      object.send(method_name, *args) if object
    end

    def method_missing(symbol, *args)
      object.send(symbol, *args)
    end

    def respond_to?(symbol, include_private=false)
      super || object.respond_to?(symbol, include_private)
    end
  end
end
