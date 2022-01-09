module Delayed
  module Launcher

    # Uses "daemons" gem to spawn as a background process.
    # Launcher::Daemonized is deprecated and will be removed
    # the next major DelayedJob version. Puma and other major
    # webservers have removed their respective "daemonized" modes.
    # See: https://github.com/puma/puma/pull/2170
    class Daemonized

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
        options[:daemonized] = true

        @options = options
        @options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        @options[:log_dir] ||= "#{Delayed.root}/log"
      end

      def run
        require_daemons!
        create_pid_dir
        setup_workers
      end

    private

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
        run_process(get_name(process_identifier), @options)
      end
      alias_method :setup_identified_worker, :setup_single_worker

      def add_worker(options)
        process_name = get_name(@worker_index)
        run_process(process_name, options)
        @worker_index += 1
      end

      def run_process(process_name, options = {})
        Delayed::Worker.before_fork
        Daemons.run_proc(process_name, :dir => options[:pid_dir], :dir_mode => :normal, :monitor => @monitor, :ARGV => @args) do |*_args|
          run_worker(process_name, options)
        end
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

      def setup_logger
        Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))
      end

      def logger
        @logger ||= Delayed::Worker.logger || (::Rails.logger if defined?(::Rails.logger)) || Logger.new(STDOUT)
      end

      def require_daemons!
        return if ENV['RAILS_ENV'] == 'test'
        begin
          require 'daemons'
        rescue LoadError
          raise "Add gem 'daemons' to your Gemfile or use --fork option."
        end
      end

      def create_pid_dir
        dir = @options[:pid_dir]
        FileUtils.mkdir_p(dir) unless File.exist?(dir)
      end
    end
  end
end
