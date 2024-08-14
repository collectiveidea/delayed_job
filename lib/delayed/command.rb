require 'optparse'

module Delayed
  class Command # rubocop:disable ClassLength
    def initialize(args)
      @options = {
        :quiet => true,
        :worker_count => 1,
        :monitor => false
      }

      @options[:args] = option_parser.parse!(args) + (@daemon_options || [])

      pools = pool_parser.pools
      @options[:pools] = pools unless pools.empty?

      validate_options!
    end

    def launch
      launcher.launch
    end

    def daemonize
      @launch_strategy ||= :daemon
      launch
    end

  private

    def launcher
      @launcher ||= launcher_class.new(@options)
    end

    def launcher_class
      case @launch_strategy
      when :daemon
        Delayed::Launcher::Daemonized
      else
        Delayed::Launcher::Forking
      end
    end

    def option_parser # rubocop:disable MethodLength, CyclomaticComplexity
      @option_parser ||= OptionParser.new do |opt|
        opt.banner = "Usage: #{Delayed.program_name} [options] start|stop|restart|run"
        opt.on('-h', '--help', 'Show this message') do
          puts opt
          exit 1
        end
        opt.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |_e|
          STDERR.puts 'The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/7'
        end
        opt.on('-d', '--daemonize', 'Launch in daemon mode') do |_fork|
          @launch_strategy ||= :daemon
        end
        opt.on('--daemon-options a, b, c', Array, 'options to be passed through to daemons gem') do |daemon_options|
          @launch_strategy ||= :daemon
          @daemon_options = daemon_options
        end
        opt.on('--fork', 'Launch in forking mode') do |_fork|
          @launch_strategy ||= :fork
        end
        opt.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = Integer(n) rescue nil
        end
        opt.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = Integer(n) rescue nil
        end
        opt.on('-n', '--num-workers=workers', 'Number of child workers to spawn') do |n|
          @options[:worker_count] = Integer(n) rescue 1
        end
        opt.on('--number_of_workers=workers', 'Number of child workers to spawn') do |n|
          STDERR.puts 'DEPRECATED: Use -n or --num-workers instead of --number_of_workers. This will be removed in the next major version.'
          @options[:worker_count] = Integer(n) rescue 1
        end
        opt.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opt.on('--log-dir=DIR', 'Specifies an alternate directory in which to store the delayed_job log.') do |dir|
          @options[:log_dir] = dir
        end
        opt.on('-v', '--verbose', 'Output additional logging') do
          @options[:quiet] = false
        end
        opt.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opt.on('-m', '--monitor', 'Start monitor process.') do
          @options[:monitor] = true
        end
        opt.on('--sleep-delay N', 'Amount of time to sleep when no jobs are found') do |n|
          @options[:sleep_delay] = Integer(n) rescue nil
        end
        opt.on('--read-ahead N', 'Number of jobs from the queue to consider') do |n|
          @options[:read_ahead] = Integer(n) rescue nil
        end
        opt.on('-p', '--prefix NAME', 'String to be prefixed to worker process names') do |prefix|
          @options[:prefix] = prefix
        end
        opt.on('--queues=queue1[,queue2]', 'Specify the job queues to work. Comma separated.') do |queues|
          @options[:queues] = queues.split(',')
        end
        opt.on('--queue=queue1[,queue2]', 'Specify the job queues to work. Comma separated.') do |queue|
          @options[:queues] = queue.split(',')
        end
        opt.on('--pools=queue1[,queue2][:worker_count][|...]', 'Specify queues and number of workers for a worker pool. Use pipe to delimit multiple pools.') do |pools|
          pool_parser.add(pools)
        end
        opt.on('--pool=queue1[,queue2][:worker_count]', 'Specify queues and number of workers for a worker pool') do |pool|
          pool_parser.add(pool)
        end
        opt.on('-x', '--exit-on-complete', 'Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.') do
          @options[:exit_on_complete] = true
        end
      end
    end

    def pool_parser
      @pool_parser ||= PoolParser.new
    end

    def validate_options!
      validate_worker_count!
      validate_priority!
      validate_identifier!
      validate_workers_and_pools!
      validate_queues_and_pools!
    end

    def validate_worker_count!
      return unless @options[:worker_count] < 1
      STDERR.puts 'WARNING: --num-workers must be 1 or greater. This will raise an ArgumentError in the next major version.'
    end

    def validate_priority!
      return unless @options[:min_priority] && @options[:max_priority] && @options[:min_priority] > @options[:max_priority]
      STDERR.puts 'WARNING: --min-priority must be less than or equal to --max-priority. This will raise an ArgumentError in the next major version.'
    end

    def validate_identifier!
      return unless @options[:identifier] && @options[:worker_count] > 1
      raise ArgumentError, 'Cannot specify both --num-workers and --identifier'
    end

    def validate_workers_and_pools!
      return unless @options[:worker_count] > 1 && @options[:pools]
      STDERR.puts 'WARNING: Cannot specify both --num-workers and --pool. This will raise an ArgumentError in the next major version.'
    end

    def validate_queues_and_pools!
      return unless @options[:queues] && @options[:pools]
      STDERR.puts 'WARNING: Cannot specify both --queues and --pool. This will raise an ArgumentError in the next major version.'
    end
  end
end
