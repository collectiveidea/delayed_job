module Delayed
  module Launcher
    class Daemonized < Base
      def initialize(options)
        raise ArgumentError, '--pid-file is for --fork mode; daemonized workers write their pidfiles in --pid-dir' if options[:pid_file]
        raise ArgumentError, '--mold is for --fork mode' if Delayed::Worker.mold_thresholds(options.fetch(:mold, Delayed::Worker.mold))
        super
      end

      def launch
        require_daemons!
        create_pid_dir
        prepare_for_fork
        setup_workers
      end

    private

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

      def setup_single_worker
        run_process(get_name(process_identifier), @options)
      end

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
    end
  end
end
