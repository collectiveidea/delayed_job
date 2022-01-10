namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task :work => :environment_options do
    Delayed::Launcher::Forking.new(@options).run
  end

  desc 'Start a delayed_job worker and exit when all available jobs are complete.'
  task :workoff => :environment_options do
    Delayed::Launcher::Forking.new(@options.merge(:exit_on_complete => true)).run
  end

  task :environment_options => :environment do
    @options = {
      :worker_count => ENV['NUM_WORKERS'] ? Integer(ENV['NUM_WORKERS']) : 1,
      :quiet => !!ENV['QUIET'] && ENV['QUIET'] !~ /\A(?:0|f|false)\z/i
    }
    @options[:min_priority] = Integer(ENV['MIN_PRIORITY']) if ENV['MIN_PRIORITY']
    @options[:max_priority] = Integer(ENV['MAX_PRIORITY']) if ENV['MAX_PRIORITY']
    @options[:sleep_delay] = Integer(ENV['SLEEP_DELAY']) if ENV['SLEEP_DELAY']
    @options[:read_ahead] = Integer(ENV['READ_AHEAD']) if ENV['READ_AHEAD']

    queues = (ENV['QUEUES'] || ENV['QUEUE'] || '').split(',')
    @options[:queues] = queues unless queues.empty?

    pools = Delayed::PoolParser.new.add(ENV['POOLS'] || ENV['POOL'] || '').pools
    @options[:pools] = pools unless pools.empty?

    if @options[:worker_count] < 1
      raise ArgumentError, 'NUM_WORKERS must be 1 or greater'
    end

    if @options[:min_priority] && @options[:max_priority] && @options[:min_priority] > @options[:max_priority]
      raise ArgumentError, 'MIN_PRIORITY must be less than or equal to MAX_PRIORITY'
    end

    if ENV['NUM_WORKERS'] && @options[:pools]
      raise ArgumentError, 'Cannot specify both NUM_WORKERS and POOLS'
    end

    if @options[:queues] && @options[:pools]
      raise ArgumentError, 'Cannot specify both QUEUES and POOLS'
    end
  end

  desc "Exit with error status if any jobs older than max_age seconds haven't been attempted yet."
  task :check, [:max_age] => :environment do |_, args|
    args.with_defaults(:max_age => 300)

    unprocessed_jobs = Delayed::Job.where('attempts = 0 AND created_at < ?', Time.now - args[:max_age].to_i).count

    if unprocessed_jobs > 0
      raise "#{unprocessed_jobs} jobs older than #{args[:max_age]} seconds have not been processed yet"
    end
  end
end
