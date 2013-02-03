begin
  require 'daemons'
rescue LoadError
  raise "You need to add gem 'daemons' to your Gemfile if you wish to use it."
end
require 'optparse'

module Delayed
  class Command
    attr_accessor :worker_count

    def initialize(args)
      @options = {
        :quiet => true,
        :pid_dir => "#{Rails.root}/tmp/pids"
      }

      @worker_count = 1
      @monitor = false

      opts = OptionParser.new do |opts|
        opts.banner = "Usage: #{File.basename($0)} [options] start|stop|restart|run"

        opts.on('-h', '--help', 'Show this message') do
          puts opts
          exit 1
        end
        opts.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |e|
          STDERR.puts "The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/#issue/7"
        end
        opts.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = n
        end
        opts.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = n
        end
        opts.on('-n', '--number_of_workers=workers', "Number of unique workers to spawn") do |worker_count|
          @worker_count = worker_count.to_i rescue 1
        end
        opts.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opts.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opts.on('-m', '--monitor', 'Start monitor process.') do
          @monitor = true
        end
        opts.on('--sleep-delay N', "Amount of time to sleep when no jobs are found") do |n|
          @options[:sleep_delay] = n.to_i
        end
        opts.on('--read-ahead N', "Number of jobs from the queue to consider") do |n|
          @options[:read_ahead] = n
        end
        opts.on('-p', '--prefix NAME', "String to be prefixed to worker process names") do |prefix|
          @options[:prefix] = prefix
        end
        opts.on('--queues=queues', "Specify which queue DJ must look up for jobs") do |queues|
          @options[:queues] = queues.split(',')
        end
        opts.on('--queue=queue', "Specify which queue DJ must look up for jobs") do |queue|
          @options[:queues] = queue.split(',')
        end
        opts.on('--exit-on-complete', "Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.") do
          @options[:exit_on_complete] = true
        end
      end
      @args = opts.parse!(args)
    end

    def daemonize
      dir = @options[:pid_dir]
      Dir.mkdir(dir) unless File.exists?(dir)

      if @worker_count > 1 && @options[:identifier]
        raise ArgumentError, 'Cannot specify both --number-of-workers and --identifier'
      elsif @worker_count == 1 && @options[:identifier]
        process_name = "delayed_job.#{@options[:identifier]}"
        run_process(process_name, dir)
      else
        worker_count.times do |worker_index|
          process_name = worker_count == 1 ? "delayed_job" : "delayed_job.#{worker_index}"
          run_process(process_name, dir)
        end
      end
    end

    def run_process(process_name, dir)
      Delayed::Worker.before_fork
      Daemons.run_proc(process_name, :dir => dir, :dir_mode => :normal, :monitor => @monitor, :ARGV => @args) do |*args|
        $0 = File.join(@options[:prefix], process_name) if @options[:prefix]
        run process_name
      end
    end

    def run(worker_name = nil)
      Dir.chdir(Rails.root)

      Delayed::Worker.after_fork
      Delayed::Worker.logger ||= Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))

      worker = Delayed::Worker.new(@options)
      worker.name_prefix = "#{worker_name} "
      worker.start
    rescue => e
      Rails.logger.fatal e
      STDERR.puts e.message
      exit 1
    end
  end
end
