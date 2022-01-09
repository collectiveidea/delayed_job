# frozen_string_literal: true

require 'fileutils'
require 'logger'

module Delayed
  module Launcher

    # Runs logger which can log even during signal traps.
    class SafeLogger
      LEVELS = %i[debug info warn error fatal].freeze

      def initialize(log_dir, logger = nil)
        @log_dir = log_dir
        setup_logger(logger)
      end

      LEVELS.each do |level|
        define_method level do |message|
          begin
            logger.send(level, message)
          rescue StandardError
            STDERR.puts(message) if message
          end
        end
      end

      private

      def setup_logger(logger)
        Delayed::Worker.logger ||= logger || file_logger
      end

      def logger
        @logger ||= Delayed::Worker.logger || rails_logger || stdout_logger
      end

      def file_logger
        FileUtils.mkdir_p(@log_dir)
        Logger.new(File.join(@log_dir, 'delayed_job.log'))
      end

      def rails_logger
        ::Rails.logger if defined?(::Rails.logger)
      end

      def stdout_logger
        Logger.new(STDOUT)
      end
    end
  end
end
