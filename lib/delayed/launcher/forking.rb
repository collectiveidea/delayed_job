# frozen_string_literal: true

require 'delayed/launcher/loggable'
require 'delayed/launcher/events'
require 'delayed/launcher/single'
require 'delayed/launcher/cluster'
require 'delayed/launcher/pooled_cluster'

module Delayed
  module Launcher

    # Parent launcher class which spawns Delayed Job child worker
    # processes in the foreground.
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Launcher`
    class Forking
      include Loggable

      DEFAULT_WORKER_CHECK_INTERVAL = 5
      DEFAULT_WORKER_TIMEOUT = 60
      DEFAULT_WORKER_SHUTDOWN_TIMEOUT = 30
      DEFAULT_WORKER_REFORK_DELAY = 900

      attr_reader :events

      def initialize(options)

        # Remove options used only for Launcher::Daemonized
        options[:daemonized] = false
        options.delete(:monitor)
        options.delete(:args)

        # Set default options
        options[:worker_count] ||= 1
        options[:worker_check_interval]   ||= DEFAULT_WORKER_CHECK_INTERVAL
        options[:worker_timeout]          ||= DEFAULT_WORKER_TIMEOUT
        options[:worker_boot_timeout]     ||= DEFAULT_WORKER_TIMEOUT
        options[:worker_shutdown_timeout] ||= DEFAULT_WORKER_SHUTDOWN_TIMEOUT
        # TODO: need phased restart timeout
        options[:worker_culling_strategy] ||= :youngest
        options[:worker_refork_delay]     ||= DEFAULT_WORKER_REFORK_DELAY
        options.delete(:worker_refork_delay) if options[:worker_refork_delay] <= 0

        options.delete(:pools) if options[:pools] == []
        options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        options[:log_dir] ||= "#{Delayed.root}/log"

        @options = options
        @events = Events.new
        # @status = :run
      end

      def run
        @runner = build_runner
        setup_signals
        @runner.run
      end

      # Begin graceful shutdown of the workers
      def stop
        # @status = :stop
        @runner.stop
      end

      # Begin forced shutdow nof the workers
      def halt
        # @status = :halt
        @runner.halt
      end

      # Begin restart of the workers
      # def restart
      #   @status = :restart
      #   @runner.restart
      # end
      #
      # # Begin phased restart of the workers
      def phased_restart
        if @runner.respond_to?(:phased_restart)
          @runner.phased_restart
        else
          logger.warn 'phased_restart called but not available.'
          # logger.warn 'phased_restart called but not available, restarting normally.'
          # restart
        end
      end

    private

      def build_runner
        if @options[:pools]
          PooledCluster.new(self, @options)
        elsif @options[:worker_count] > 1
          Cluster.new(self, @options)
        else
          Single.new(self, @options)
        end
      end

      def setup_signals
        # setup_signal_restart
        setup_signal_phased_restart
        setup_signal_term
        setup_signal_int
      end

      # def setup_signal_restart
      #   Signal.trap('SIGUSR2') { restart }
      # rescue Exception # rubocop:disable Lint/RescueException
      #   logger.info '*** SIGUSR2 not implemented, signal based restart unavailable!'
      # end

      def setup_signal_phased_restart
        return if Delayed.jruby?
        Signal.trap('SIGUSR1') { phased_restart }
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGUSR1 not implemented, signal based restart unavailable!'
      end

      def setup_signal_term
        Signal.trap('SIGTERM') do
          stop
          raise(SignalException, 'SIGTERM') if raise_sigterm
        end
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGTERM not implemented, signal based gracefully stopping unavailable!'
      end

      def setup_signal_int
        Signal.trap('SIGINT') do
          stop
          raise(SignalException, 'SIGINT') if raise_sigint
        end
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGINT not implemented, signal based gracefully stopping unavailable!'
      end

      def raise_sigterm
        Delayed::Worker.raise_signal_exceptions
      end

      def raise_sigint
        Delayed::Worker.raise_signal_exceptions && Delayed::Worker.raise_signal_exceptions != :term
      end
    end
  end
end
