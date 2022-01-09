require 'active_support/concern'

module Delayed
  module Launcher
    module Loggable
      extend ActiveSupport::Concern

      included do
        private

        def setup_logger
          Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))
        end

        def logger
          @logger ||= Delayed::Worker.logger || (::Rails.logger if defined?(::Rails.logger)) || Logger.new(STDOUT)
        end
      end
    end
  end
end
