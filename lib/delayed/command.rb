require 'optparse'

module Delayed
  class Command # rubocop:disable Metrics/ClassLength
    def initialize(args)
      @options = {
        :quiet => true,
        :processes => 1,
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

    def option_parser # rubocop:disable Metrics/MethodLength
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
          @options[:min_priority] = parse(:min_priority, n)
        end
        opt.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = parse(:max_priority, n)
        end
        opt.on('-n', '--processes=N', 'Number of worker processes to spawn') do |n|
          @options[:processes] = parse(:processes, n)
        end
        opt.on('--num-workers=N', 'DEPRECATED: Use --processes') do |n|
          STDERR.puts 'DEPRECATED: Use -n or --processes instead of --num-workers. This will be removed in the next major version.'
          @options[:processes] = parse(:processes, n, '--num-workers')
        end
        opt.on('-t', '--threads=N', 'Number of threads per worker process') do |n|
          @options[:threads] = parse(:threads, n)
        end
        opt.on('--number_of_workers=N', 'DEPRECATED: Use --processes') do |n|
          STDERR.puts 'DEPRECATED: Use -n or --processes instead of --number_of_workers. This will be removed in the next major version.'
          @options[:processes] = parse(:processes, n, '--number_of_workers')
        end
        opt.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opt.on('--pid-file[=PATH]', 'With --fork, write the parent process id to PATH (default: <pid-dir>/delayed_job.pid) and refuse to start if that process is running') do |path|
          @options[:pid_file] = path || true
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
        opt.on('--shutdown-timeout N', 'Seconds to let running jobs finish when stopping before interrupting and releasing them (default: wait for them)') do |n|
          @options[:shutdown_timeout] = parse(:shutdown_timeout, n)
        end
        opt.on('--lock-heartbeat N', 'Refresh the locks of running jobs every N seconds, so a dead or hung worker\'s jobs are picked up after --lock-timeout (default: off)') do |n|
          @options[:lock_heartbeat_interval] = parse(:lock_heartbeat_interval, n)
        end
        opt.on('--lock-timeout N', 'With --lock-heartbeat, seconds after which a lock that was not refreshed counts as abandoned (default: 300)') do |n|
          @options[:lock_timeout] = parse(:lock_timeout, n)
        end
        opt.on('--count-shutdown-interrupts', 'Count a job interrupted by shutdown as a failed attempt (default: release it, attempts unchanged)') do
          @options[:count_shutdown_interrupts] = true
        end
        opt.on('--silence-logging', "Don't log the database queries of polling for jobs and refreshing their locks") do
          @options[:silence_logging] = true
        end
        opt.on('--sleep-delay N', 'Seconds to sleep when no jobs are found (default: 1)') do |n|
          @options[:sleep_delay] = parse(:sleep_delay, n)
        end
        opt.on('--prefetch N', 'Jobs each thread may hold queued behind the one it runs, to start the next one without waiting for a poll (default: 0)') do |n|
          @options[:prefetch] = parse(:prefetch, n)
        end
        opt.on('--batch-reserve', 'Reserve jobs for several free threads in one query, on backends that support it (e.g. delayed_job_mongoid)') do
          @options[:batch_reserve] = true
        end
        opt.on('--prefetch-dynamic', 'Scale the prefetch queue depth with demand: from 0, one level deeper after each poll that gets every job it asks for, back to 0 after one that gets fewer') do
          @options[:prefetch_dynamic] = true
        end
        opt.on('--mold[=JOBS]', Array, 'Experimental, with --fork: once a child process has performed JOBS jobs (comma-separated for successive thresholds; default 1000), ' \
                                       'refork every child process from it, sharing its warmed memory. SIGURG to the parent promotes one at any time.') do |jobs|
          @options[:mold] = parse_mold(jobs)
        end
        opt.on('--read-ahead N', 'Number of jobs from the queue to consider') do |n|
          @options[:read_ahead] = parse(:read_ahead, n)
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
        opt.on('--pools=queue1[,queue2][:processes][|...]', 'Specify queues and number of processes for a worker pool. Use pipe to delimit multiple pools.') do |pools|
          pool_parser.add(pools)
        end
        opt.on('--pool=queue1[,queue2][:processes]', 'Specify queues and number of processes for a worker pool') do |pool|
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

    # --mold alone: the default threshold.
    def parse_mold(jobs)
      return true unless jobs
      jobs.map { |n| LaunchOptions.parse_mold(n, '--mold') }
    end

    def parse(option, value, name = LaunchOptions::CLI_NAMES.fetch(option))
      LaunchOptions.parse(option, value, name)
    end

    # Same rules as rake jobs:work.
    def validate_options!
      LaunchOptions.validate!(@options, LaunchOptions::CLI_NAMES)
      validate_daemon_command!
    end

    DAEMON_COMMANDS = %w[stop restart reload zap status].freeze

    # --fork runs in the foreground, with no daemon pidfiles to stop or
    # query a running launcher by.
    def validate_daemon_command!
      return unless @launch_strategy == :fork
      command = (@options[:args] & DAEMON_COMMANDS).first
      return unless command
      raise ArgumentError, "--fork runs in the foreground and does not support #{command}: " \
                           'stop it with a signal (TERM, INT or QUIT)'
    end
  end
end
