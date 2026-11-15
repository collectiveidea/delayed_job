module Delayed
  module Launcher
    class Base
      attr_accessor :processes,
                    :pools,
                    :process_prefix,
                    :process_identifier

      # Deprecated.
      alias_method :worker_count, :processes
      alias_method :worker_count=, :processes=

      def initialize(options)
        @worker_index = 0
        processes = options.delete(:processes)
        worker_count = options.delete(:worker_count)
        @processes = processes || worker_count || 1
        @pools = options.delete(:pools)
        @pools = nil if @pools == []
        @monitor = options.delete(:monitor)
        @process_prefix = options.delete(:prefix)
        @process_identifier = options.delete(:identifier)
        @args = options.delete(:args)

        @options = options
        @options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        @options[:log_dir] ||= "#{Delayed.root}/log"
      end

      def launch
        raise NotImplementedError, '#launch must be implemented in subclass'
      end

    protected

      def setup_logger
        Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))
      end

      # Maximizes copy-on-write sharing with forked workers.
      def prepare_for_fork
        eager_load_application
        warmup_heap
      end

      # Rake tasks don't eager load by default, so each worker would autoload
      # its own copy. Skipped with code reloading, which isn't shared anyway.
      def eager_load_application
        return unless defined?(::Rails.application) && ::Rails.application
        return unless ::Rails.application.config.cache_classes
        ::Rails.application.eager_load!
      end

      def warmup_heap
        if Process.respond_to?(:warmup)
          Process.warmup
        else
          GC.start
          GC.compact if GC.respond_to?(:compact)
        end
      rescue NotImplementedError
        nil # GC.compact is unsupported on this platform
      end

      def setup_workers
        if pools
          setup_pooled_workers
        elsif process_identifier
          setup_identified_worker
        elsif multiple_processes?
          setup_multiple_workers
        else
          setup_single_worker
        end
      end

      def setup_pooled_workers
        pools.each do |queues, pool_process_count|
          options = @options.merge(:queues => queues)
          pool_process_count.times { add_worker_safely(options) }
        end
      end

      def setup_multiple_workers
        processes.times { add_worker_safely(@options) }
      end

      # The forking launcher retries a failed fork with back-off.
      def add_worker_safely(options)
        add_worker(options)
      end

      def multiple_processes?
        processes > 1
      end

      def run_dispatcher(_worker_name, dispatcher, pending_signals)
        dispatcher.start(pending_signals)
      end

      def setup_single_worker
        raise NotImplementedError, '#setup_single_worker must be implemented in subclass'
      end

      def setup_identified_worker
        setup_single_worker
      end

      def add_worker(_options)
        raise NotImplementedError, '#add_worker must be implemented in subclass'
      end

      def run_worker(worker_name, options, pending_signals = [])
        Dir.chdir(Delayed.root)
        set_process_name(worker_name)
        Delayed::Worker.after_fork
        setup_logger
        dispatcher = Delayed::Dispatcher.new(options.merge(:supervisor_pid => supervisor_pid, :procline => $0))
        dispatcher.name_prefix = "#{worker_name} "
        run_dispatcher(worker_name, dispatcher, pending_signals)
      rescue StandardError => error
        STDERR.puts error.message
        STDERR.puts error.backtrace
        logger.fatal(error)
        exit_with_error_status
      end

      # Overridden by the forking launcher; daemonized workers are detached
      # and unsupervised.
      def supervisor_pid
        nil
      end

      def threads(options)
        (options[:threads] || 1).to_i
      end

      def prefetch(options)
        (options[:prefetch] || Delayed::Worker.prefetch).to_i
      end

      def set_process_name(name) # rubocop:disable Naming/AccessorMethodName
        $0 = process_prefix ? File.join(process_prefix, name) : name
      end

      def get_name(label)
        "delayed_job#{".#{label}" if label}"
      end

      def exit_with_error_status
        exit(1)
      end

      def logger
        @logger ||= Delayed::Worker.logger || (::Rails.logger if defined?(::Rails.logger)) || Logger.new(STDOUT)
      end
    end
  end
end
