namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task :work => :environment_options do
    Delayed::Launcher::Forking.new(@options).launch
  end

  desc 'Start a delayed_job worker and exit when all available jobs are complete.'
  task :workoff => :environment_options do
    Delayed::Launcher::Forking.new(@options.merge(:exit_on_complete => true)).launch
  end

  task :environment_options => :environment do
    names = Delayed::LaunchOptions::ENV_NAMES
    number = lambda do |option, variable = names.fetch(option)|
      Delayed::LaunchOptions.parse(option, ENV[variable], variable) if ENV[variable]
    end
    flag = ->(variable) { !!ENV[variable] && ENV[variable] !~ /\A(?:|0|f|false|n|no|off)\z/i }

    @options = {
      # NUM_WORKERS: deprecated alias.
      :processes => number.call(:processes) || number.call(:processes, 'NUM_WORKERS') || 1,
      :quiet => flag.call('QUIET')
    }
    (Delayed::LaunchOptions::RULES.keys - [:processes]).each do |option|
      value = number.call(option)
      @options[option] = value unless value.nil?
    end
    %w[PREFETCH_DYNAMIC BATCH_RESERVE SILENCE_LOGGING COUNT_SHUTDOWN_INTERRUPTS].each do |variable|
      @options[variable.downcase.to_sym] = true if flag.call(variable)
    end
    # MOLD=1000,2000 (thresholds), or MOLD=true for the default (1000).
    if flag.call('MOLD')
      mold = ENV['MOLD'].strip
      @options[:mold] = mold =~ /\A(?:t|true|y|yes|on)\z/i ? true : mold.split(',').map { |n| Delayed::LaunchOptions.parse_mold(n, 'MOLD') }
    end
    # PIDFILE=path, or PIDFILE=1 for tmp/pids/delayed_job.pid.
    if flag.call('PIDFILE')
      @options[:pid_file] = ENV['PIDFILE'] =~ /\A(?:1|t|true|y|yes|on)\z/i ? true : ENV['PIDFILE']
    end

    queues = (ENV['QUEUES'] || ENV['QUEUE'] || '').split(',')
    @options[:queues] = queues unless queues.empty?

    pools = Delayed::PoolParser.new.add(ENV['POOLS'] || ENV['POOL'] || '').pools
    @options[:pools] = pools unless pools.empty?

    # Same rules as script/delayed_job.
    Delayed::LaunchOptions.validate!(@options, names)
  end

  desc "Exit with error status if any jobs older than max_age seconds haven't been attempted yet."
  task :check, [:max_age] => :environment do |_, args|
    args.with_defaults(:max_age => 300)

    unprocessed_jobs = Delayed::Job.where('attempts = 0 AND created_at < ?', Time.now - args[:max_age].to_i).count

    raise "#{unprocessed_jobs} jobs older than #{args[:max_age]} seconds have not been processed yet" if unprocessed_jobs > 0
  end
end
