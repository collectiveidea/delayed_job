namespace :jobs do
  desc "Clear the delayed_job queue."
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc "Start a delayed_job worker."
  task :work => :environment do
    Delayed::Worker.new(:min_priority => ENV['MIN_PRIORITY'], :max_priority => ENV['MAX_PRIORITY'], :queues => (ENV['QUEUES'] || ENV['QUEUE'] || '').split(','), :quiet => false).start
  end

  desc "Works all jobs in the queue (if any) and exits."
  task :work_once => :environment do
    job_count = Delayed::Job.count
    puts "There are #{job_count} jobs in the queue."
    result = Delayed::Job.work_off job_count
    puts "#{result.sum} jobs processed: #{result.first} succeeded, #{result.last} failed." 
  end

end
