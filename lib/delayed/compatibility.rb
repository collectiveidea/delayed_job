require 'active_support/version'

module Delayed
  module Compatibility
    # simplecov:disable - depends on the Rails version
    if ActiveSupport::VERSION::MAJOR >= 4
      def self.executable_prefix
        'bin'
      end
    else
      def self.executable_prefix
        'script'
      end
    end
    # simplecov:enable
  end
end
