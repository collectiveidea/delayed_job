require 'delayed/launcher/runner'

module Delayed
  module Launcher

    # This class is instantiated by `Delayed::Launcher`.
    # It boots and runs a Delayed Job application using a
    # single in-process worker. For example: `$ delayed_job -n1`
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Single`
    class Single < Runner

      def run
        set_process_name(get_name(process_identifier))
        worker = start_worker
        events.fire(:on_booted)
        worker
      end

      def stop
        schedule_halt
        stop_worker
        logger.info "#{process_name} exited gracefully - pid #{$$}"
        exit(0)
      end

      # def restart
      #   logger.info "#{process_name} restarting... - pid #{$$}"
      #   stop_worker
      #   start_worker
      #   logger.info "#{process_name} restarted - pid #{$$}"
      # end

      def halt(exit_status = 0, message = nil)
        logger.warn "#{process_name} exited forcefully #{message} - pid #{$$}"
        exit(exit_status)
      end

    private

      def start_worker
        @worker = Delayed::Worker.new(@options).start
      end

      def stop_worker
        @worker.stop
      end

      def schedule_halt
        timeout = @options[:worker_shutdown_timeout]
        return unless timeout
        Thread.new do
          sleep(timeout)
          halt(1, "after #{timeout} second timeout")
        end
      end

      def process_name
        get_name(process_identifier)
      end
    end
  end
end
