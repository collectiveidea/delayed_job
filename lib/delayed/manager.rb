module Delayed
  module Manager
    extend self

    def instance
      @@instance ||= init_manager
    end

    def init_manager
      handler = Delayed::Worker.auto_scale_manager
      return handler unless [Symbol, Array, String].include? handler.class

      options = {}
      handler, options = handler if handler.is_a?(Array)
      require File.dirname(__FILE__) + "/manager/#{handler}"
      const_get(handler.to_s.capitalize).new(options)
    end

    def method_missing(m, *args)
      instance.send(m, *args)
    end
  end
end
