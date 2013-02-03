namespace :jobs do
  desc "Clear the delayed_job queue."
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc "Start a delayed_job worker."
  task :work => :environment_options do
    Delayed::Worker.new(@worker_options).start
  end

  desc "Start a delayed_job worker and exit when all available jobs are complete."
  task :workoff => :environment_options do
    Delayed::Worker.new(@worker_options.merge({:exit_on_complete => true})).start
  end

  task :environment_options => :environment do
    @worker_options = {
      :min_priority => ENV['MIN_PRIORITY'],
      :max_priority => ENV['MAX_PRIORITY'],
      :queues => (ENV['QUEUES'] || ENV['QUEUE'] || '').split(','),
      :quiet => false
    }
  end
end
