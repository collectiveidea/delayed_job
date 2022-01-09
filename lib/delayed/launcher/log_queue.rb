# frozen_string_literal: true

require 'fileutils'
require 'logger'

module Delayed
  module Launcher

    # Runs logger on its own thead to allow logging even during signal traps.
    # See: https://bugs.ruby-lang.org/issues/14222
    class LogQueue
      LEVELS = %i[debug info warn error fatal].freeze

      def initialize(log_dir, logger = nil)
        @log_dir = log_dir
        @queue = Queue.new
        setup_logger(logger)
        setup_loop
      end

      LEVELS.each do |level|
        define_method level do |message|
          @queue << [level, message]
        end
      end

      private

      def setup_loop
        Thread.start do
          nil while pop_queue
        end
      end

      def pop_queue
        logger.send(*@queue.pop)
      end

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
