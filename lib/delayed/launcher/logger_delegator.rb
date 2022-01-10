# frozen_string_literal: true

require 'fileutils'
require 'logger'

# TODO: remove this class
module Delayed
  module Launcher

    # Runs logger which can log even during signal traps.
    class LoggerDelegator
      LEVELS = %i[debug info warn error fatal].freeze

      def initialize(log_dir, logger = nil)
        @log_dir = log_dir
        setup_logger(logger)
      end

      delegate *LEVELS, to: :logger

      def logger
        @logger ||= Delayed::Worker.logger || rails_logger || stdout_logger
      end

      private

      def setup_logger(logger)
        Delayed::Worker.logger ||= logger || file_logger
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

      # FROM PUMA
      #
      # def log(str)
      #   @events.log str
      # end
      #
      # def error(str)
      #   @events.error str
      # end
      #
      # def debug(str)
      #   @events.log "- #{str}" if @options[:debug]
      # end
      #
      # def redirected_io?
      #   @options[:redirect_stdout] || @options[:redirect_stderr]
      # end
      #
      # def redirect_io
      #   stdout = @options[:redirect_stdout]
      #   stderr = @options[:redirect_stderr]
      #   append = @options[:redirect_append]
      #
      #   if stdout
      #     ensure_output_directory_exists(stdout, 'STDOUT')
      #
      #     STDOUT.reopen stdout, (append ? "a" : "w")
      #     STDOUT.puts "=== puma startup: #{Time.now} ==="
      #     STDOUT.flush unless STDOUT.sync
      #   end
      #
      #   if stderr
      #     ensure_output_directory_exists(stderr, 'STDERR')
      #
      #     STDERR.reopen stderr, (append ? "a" : "w")
      #     STDERR.puts "=== puma startup: #{Time.now} ==="
      #     STDERR.flush unless STDERR.sync
      #   end
      #
      #   if @options[:mutate_stdout_and_stderr_to_sync_on_write]
      #     STDOUT.sync = true
      #     STDERR.sync = true
      #   end
      # end
      #
      # private
      # def ensure_output_directory_exists(path, io_name)
      #   unless Dir.exist?(File.dirname(path))
      #     raise "Cannot redirect #{io_name} to #{path}"
      #   end
      # end
    end
  end
end
