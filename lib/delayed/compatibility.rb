require 'active_support/version'

module Delayed
  module Compatibility
    if ActiveSupport::VERSION::MAJOR >= 4
      def self.executable_prefix
        'bin'
      end
    else
      def self.executable_prefix
        'script'
      end
    end
  end
end
