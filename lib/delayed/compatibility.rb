require 'active_support/version'

module Delayed
  module Compatibility
    if ActiveSupport::VERSION::MAJOR >= 4
      def self.executable_prefix
        'bin'
      end

      def self.proxy_object_class
        require 'active_support/proxy_object'
        ActiveSupport::ProxyObject
      end
    else
      def self.executable_prefix
        'script'
      end

      def self.proxy_object_class
        require 'active_support/basic_object'
        ActiveSupport::BasicObject
      end
    end
  end
end
