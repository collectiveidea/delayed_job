module Delayed
  module Launcher
    class Base
      attr_accessor :worker_count,
                    :pools,
                    :process_prefix,
                    :process_identifier

      def initialize(options)
        @worker_index = 0
        @worker_count = options.delete(:worker_count) || 1
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

      def setup_workers
        if pools
          setup_pooled_workers
        elsif process_identifier
          setup_identified_worker
        elsif worker_count > 1
          setup_multiple_workers
        else
          setup_single_worker
        end
      end

      def setup_pooled_workers
        pools.each do |queues, pool_worker_count|
          options = @options.merge(:queues => queues)
          pool_worker_count.times { add_worker(options) }
        end
      end

      def setup_multiple_workers
        worker_count.times { add_worker(@options) }
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

      def run_worker(worker_name, options)
        Dir.chdir(Delayed.root)
        set_process_name(worker_name)
        Delayed::Worker.after_fork
        setup_logger
        worker = Delayed::Worker.new(options)
        worker.name_prefix = "#{worker_name} "
        worker.start
      rescue => e
        STDERR.puts e.message
        STDERR.puts e.backtrace
        logger.fatal(e)
        exit_with_error_status
      end

      def set_process_name(name) # rubocop:disable AccessorMethodName
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
