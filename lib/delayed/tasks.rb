namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task :work => :environment_options do
    Delayed::Worker.new(@worker_options).start
  end

  desc 'Start a delayed_job worker and exit when all available jobs are complete.'
  task :workoff => :environment_options do
    Delayed::Worker.new(@worker_options.merge(:exit_on_complete => true)).start
  end

  task :environment_options => :environment do
    def read_env(name)
      return ::ENV[name] if ::ENV.key?(name)

      deprecated_name = name[/DELAYED_JOB_(.+)/, 1]
      return unless ::ENV.key?(deprecated_name)

      warn "[DEPRECATION] '#{deprecated_name}' for configuration is deprecated. Use '#{name}'"
      ::ENV[deprecated_name]
    end

    @worker_options = {
      :min_priority => read_env('DELAYED_JOB_MIN_PRIORITY'),
      :max_priority => read_env('DELAYED_JOB_MAX_PRIORITY'),
      :queues => (read_env('DELAYED_JOB_QUEUES') || read_env('DELAYED_JOB_QUEUE') || '').split(','),
      :quiet => read_env('DELAYED_JOB_QUIET')
    }

    @worker_options[:sleep_delay] = read_env('DELAYED_JOB_SLEEP_DELAY').to_i if read_env('DELAYED_JOB_SLEEP_DELAY')
    @worker_options[:read_ahead] = read_env('DELAYED_JOB_READ_AHEAD').to_i if read_env('DELAYED_JOB_READ_AHEAD')
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
