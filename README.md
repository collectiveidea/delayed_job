Delayed::Job
============
[![Gem Version](https://badge.fury.io/rb/delayed_job.png)][gem]
[![Build Status](https://secure.travis-ci.org/collectiveidea/delayed_job.png?branch=master)][travis]
[![Dependency Status](https://gemnasium.com/collectiveidea/delayed_job.png?travis)][gemnasium]
[![Code Climate](https://codeclimate.com/badge.png)][codeclimate]
[gem]: https://rubygems.org/gems/delayed_job
[travis]: http://travis-ci.org/collectiveidea/delayed_job
[gemnasium]: https://gemnasium.com/collectiveidea/delayed_job
[codeclimate]: https://codeclimate.com/github/collectiveidea/delayed_job

Delayed::Job (or DJ) encapsulates the common pattern of asynchronously executing
longer tasks in the background.

It is a direct extraction from Shopify where the job table is responsible for a
multitude of core tasks. Amongst those tasks are:

* sending massive newsletters
* image resizing
* http downloads
* updating smart collections
* updating solr, our search server, after product changes
* batch imports
* spam checks

[Follow us on Twitter][twitter] to get updates and notices about new releases.

[twitter]: https://twitter.com/delayedjob

Installation
============
delayed_job 3.0.0 only supports Rails 3.0+. See the [2.0
branch](https://github.com/collectiveidea/delayed_job/tree/v2.0) for Rails 2.

delayed_job supports multiple backends for storing the job queue. [See the wiki
for other backends](http://wiki.github.com/collectiveidea/delayed_job/backends).

If you plan to use delayed_job with Active Record, add `delayed_job_active_record` to your `Gemfile`.

    gem 'delayed_job_active_record'

If you plan to use delayed_job with Mongoid, add `delayed_job_mongoid` to your `Gemfile`.

    gem 'delayed_job_mongoid'

Run `bundle install` to install the backend and delayed_job gems.

The Active Record backend requires a jobs table. You can create that table by
running the following command:

    rails generate delayed_job:active_record
    rake db:migrate

Upgrading from 2.x to 3.0.0 on Active Record
============================================
Delayed Job 3.0.0 introduces a new column to the delayed_jobs table.

If you're upgrading from Delayed Job 2.x, run the upgrade generator to create a migration to add the column.

    rails generate delayed_job:upgrade
    rake db:migrate

Queuing Jobs
============
Call `.delay.method(params)` on any object and it will be processed in the background.

    # without delayed_job
    @user.activate!(@device)

    # with delayed_job
    @user.delay.activate!(@device)

If a method should always be run in the background, you can call
`#handle_asynchronously` after the method declaration:

```ruby
class Device
  def deliver
    # long running method
  end
  handle_asynchronously :deliver
end

device = Device.new
device.deliver
```

handle_asynchronously can take as options anything you can pass to delay. In
addition, the values can be Proc objects allowing call time evaluation of the
value. For some examples:

```ruby
class LongTasks
  def send_mailer
    # Some other code
  end
  handle_asynchronously :send_mailer, :priority => 20

  def in_the_future
    # Some other code
  end
  # 5.minutes.from_now will be evaluated when in_the_future is called
  handle_asynchronously :in_the_future, :run_at => Proc.new { 5.minutes.from_now }

  def self.when_to_run
    2.hours.from_now
  end

  def call_a_class_method
    # Some other code
  end
  handle_asynchronously :call_a_class_method, :run_at => Proc.new { when_to_run }

  attr_reader :how_important

  def call_an_instance_method
    # Some other code
  end
  handle_asynchronously :call_an_instance_method, :priority => Proc.new {|i| i.how_important }
end
```

Rails 3 Mailers
===============
Due to how mailers are implemented in Rails 3, we had to do a little work around to get delayed_job to work.

```ruby
# without delayed_job
Notifier.signup(@user).deliver

# with delayed_job
Notifier.delay.signup(@user)
```

Remove the `.deliver` method to make it work. It's not ideal, but it's the best
we could do for now.

Named Queues
============
DJ 3 introduces Resque-style named queues while still retaining DJ-style
priority. The goal is to provide a system for grouping tasks to be worked by
separate pools of workers, which may be scaled and controlled individually.

Jobs can be assigned to a queue by setting the `queue` option:

```ruby
object.delay(:queue => 'tracking').method

Delayed::Job.enqueue job, :queue => 'tracking'

handle_asynchronously :tweet_later, :queue => 'tweets'
```

Running Jobs
============
`script/delayed_job` can be used to manage a background process which will
start working off jobs.

To do so, add `gem "daemons"` to your `Gemfile` and make sure you've run `rails
generate delayed_job`.

You can then do the following:

    RAILS_ENV=production script/delayed_job start
    RAILS_ENV=production script/delayed_job stop

    # Runs two workers in separate processes.
    RAILS_ENV=production script/delayed_job -n 2 start
    RAILS_ENV=production script/delayed_job stop

    # Set the --queue or --queues option to work from a particular queue.
    RAILS_ENV=production script/delayed_job --queue=tracking start
    RAILS_ENV=production script/delayed_job --queues=mailers,tasks start

    # Runs all available jobs and the exits
    RAILS_ENV=production script/delayed_job start --exit-on-complete
    # or to run in the foreground
    RAILS_ENV=production script/delayed_job run --exit-on-complete

Workers can be running on any computer, as long as they have access to the
database and their clock is in sync. Keep in mind that each worker will check
the database at least every 5 seconds.

You can also invoke `rake jobs:work` which will start working off jobs. You can
cancel the rake task with `CTRL-C`.

If you want to just run all available jobs and exit you can use `rake jobs:workoff`

Work off queues by setting the `QUEUE` or `QUEUES` environment variable.

    QUEUE=tracking rake jobs:work
    QUEUES=mailers,tasks rake jobs:work

Custom Jobs
===========
Jobs are simple ruby objects with a method called perform. Any object which responds to perform can be stuffed into the jobs table. Job objects are serialized to yaml so that they can later be resurrected by the job runner.

```ruby
class NewsletterJob < Struct.new(:text, :emails)
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end
end

Delayed::Job.enqueue NewsletterJob.new('lorem ipsum...', Customers.find(:all).collect(&:email))
```

Hooks
=====
You can define hooks on your job that will be called at different stages in the process:

```ruby
class ParanoidNewsletterJob < NewsletterJob
  def enqueue(job)
    record_stat 'newsletter_job/enqueue'
  end

  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def before(job)
    record_stat 'newsletter_job/start'
  end

  def after(job)
    record_stat 'newsletter_job/after'
  end

  def success(job)
    record_stat 'newsletter_job/success'
  end

  def error(job, exception)
    Airbrake.notify(exception)
  end

  def failure
    page_sysadmin_in_the_middle_of_the_night
  end
end
```

Gory Details
============
The library revolves around a delayed_jobs table which looks as follows:

```ruby
create_table :delayed_jobs, :force => true do |table|
  table.integer  :priority, :default => 0      # Allows some jobs to jump to the front of the queue
  table.integer  :attempts, :default => 0      # Provides for retries, but still fail eventually.
  table.text     :handler                      # YAML-encoded string of the object that will do work
  table.text     :last_error                   # reason for last failure (See Note below)
  table.datetime :run_at                       # When to run. Could be Time.zone.now for immediately, or sometime in the future.
  table.datetime :locked_at                    # Set when a client is working on this object
  table.datetime :failed_at                    # Set when all retries have failed (actually, by default, the record is deleted instead)
  table.string   :locked_by                    # Who is working on this object (if locked)
  table.string   :queue                        # The name of the queue this job is in
  table.timestamps
end
```

On failure, the job is scheduled again in 5 seconds + N ** 4, where N is the number of retries.

The default Worker.max_attempts is 25. After this, the job either deleted (default), or left in the database with "failed_at" set.
With the default of 25 attempts, the last retry will be 20 days later, with the last interval being almost 100 hours.

The default Worker.max_run_time is 4.hours. If your job takes longer than that, another computer could pick it up. It's up to you to
make sure your job doesn't exceed this time. You should set this to the longest time you think the job could take.

By default, it will delete failed jobs (and it always deletes successful jobs). If you want to keep failed jobs, set
Delayed::Worker.destroy_failed_jobs = false. The failed jobs will be marked with non-null failed_at.

By default all jobs are scheduled with priority = 0, which is top priority. You can change this by setting Delayed::Worker.default_priority to something else. Lower numbers have higher priority.

The default behavior is to read 5 jobs from the queue when finding an available job. You can configure this by setting Delayed::Worker.read_ahead.

It is possible to disable delayed jobs for testing purposes. Set Delayed::Worker.delay_jobs = false to execute all jobs realtime.

Here is an example of changing job parameters in Rails:

```ruby
# config/initializers/delayed_job_config.rb
Delayed::Worker.destroy_failed_jobs = false
Delayed::Worker.sleep_delay = 60
Delayed::Worker.max_attempts = 3
Delayed::Worker.max_run_time = 5.minutes
Delayed::Worker.read_ahead = 10
Delayed::Worker.delay_jobs = !Rails.env.test?
```

Cleaning up
===========
You can invoke `rake jobs:clear` to delete all jobs in the queue.

Mailing List
============
Join us on the [mailing list](http://groups.google.com/group/delayed_job)
