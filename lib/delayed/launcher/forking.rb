module Delayed
  module Launcher
    class Forking < Base
      KILL_TIMEOUT = 30

      def launch
        @stopped = !!@options[:exit_on_complete]
        @killed = false
        setup_logger
        trap_signals
        Delayed::Worker.before_fork if worker_count > 1
        setup_workers
        run_loop if worker_count > 1
        before_graceful_exit
      end

      def shutdown(timeout = nil)
        @stopped = true
        message = " with #{timeout} second grace period" if timeout
        logger.info "Shutdown invoked#{message}"
        signal_workers('TERM')
        schedule_kill(timeout) if timeout
      end

      def kill(exit_status = 0, message = nil)
        @stopped = true
        @killed = true
        message = " #{message}" if message
        logger.warn "Kill invoked#{message}"
        signal_workers('KILL')
        logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
        exit(exit_status)
      end

    private

      def trap_signals
        trap_shutdown_signal('INT')
        trap_shutdown_signal('TERM')
      end

      # Trapped signals are forwarded worker processes.
      # Hence it is not necessary to explicitly shutdown workers;
      # we only need to stop the run loop.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          @stopped = true
        end
      end

      def workers
        @workers ||= {}
      end

      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Worker.new(@options).start
      end

      def add_worker(options)
        worker_name = get_name(@worker_index)
        worker_pid = fork_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"

        workers[worker_pid] = [worker_name, queues]
        @worker_index += 1
      end

      def fork_worker(worker_name, options)
        fork { run_worker(worker_name, options) }
      end

      def run_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
        loop do
          worker_pid = Process.wait
          next unless workers.key?(worker_pid)
          worker_name, queues = workers.delete(worker_pid)
          child_status = $?
          logger.info "Worker #{worker_name} exited - #{child_status}"

          # If any child was SIGKILL'ed, we must shutdown all children.
          # This first will attempt a graceful SIGTERM of the children,
          # followed by a SIGKILL after a timeout period.
          if child_status.termsig == 9 && !@killed
            @killed = true
            logger.warn "Worker #{worker_name} SIGKILL detected. #{parent_name} shutting down..."
            shutdown(KILL_TIMEOUT)
            next
          end

          break if @stopped && workers.empty?
          next if @stopped
          options = @options
          options = options.merge(:queues => queues) if queues
          add_worker(options)
        end
      rescue Errno::ECHILD
        logger.warn 'No worker processes found'
      end

      def schedule_kill(timeout)
        Thread.new do
          sleep(timeout)
          kill(1, "after #{timeout} second timeout")
        end
      end

      def signal_workers(signal)
        workers.each do |pid, (worker_name, _)|
          logger.info "Sent SIG#{signal} to worker #{worker_name}"
          Process.kill(signal, pid)
        end
      end

      def before_graceful_exit
        logger.info "#{parent_name} exited gracefully - pid #{$$}"
      end

      def parent_name
        "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1}"
      end
    end
  end
end
