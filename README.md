**If you're viewing this at https://github.com/collectiveidea/delayed_job,
you're reading the documentation for the master branch.
[View documentation for the latest release
(4.1.9).](https://github.com/collectiveidea/delayed_job/tree/v4.1.9)**

# Delayed Job

[![Gem Version](https://badge.fury.io/rb/delayed_job.svg)][gem]
![CI](https://github.com/collectiveidea/delayed_job/workflows/CI/badge.svg)
[![Code Climate](https://codeclimate.com/github/collectiveidea/delayed_job.svg)][codeclimate]
[![Coverage Status](https://coveralls.io/repos/collectiveidea/delayed_job/badge.svg?branch=master)][coveralls]

[gem]: https://rubygems.org/gems/delayed_job
[codeclimate]: https://codeclimate.com/github/collectiveidea/delayed_job
[coveralls]: https://coveralls.io/r/collectiveidea/delayed_job

Delayed Job encapsulates the common pattern of asynchronously executing
longer tasks in the background. Examples of such tasks include:

* Sending emails
* Image resizing
* HTTP downloads
* Updating smart collections
* Updating Solr, our search server, after product changes
* Batch imports
* Spam checks

## Installation

### Version Support

Delayed Job 4.x only supports Rails 3.0+.

### Configuring your Database

Delayed Job supports multiple backends for storing the job queue. [See the wiki
for other backends](https://github.com/collectiveidea/delayed_job/wiki/Backends).

To use with Active Record, add `delayed_job_active_record` to your `Gemfile`.

```ruby
gem 'delayed_job_active_record'
```

To use with Mongoid, add `delayed_job_mongoid` to your `Gemfile`.

```ruby
gem 'delayed_job_mongoid'
```

Run `bundle install` to install the backend and `delayed_job` gems.

The Active Record backend requires a jobs table. You can create that table by
running the following command:

```
rails generate delayed_job:active_record
rake db:migrate
```

### Active Job

To use Delayed Job with Active Job (Rails 4.2+), set the `queue_adapter` in `config/application.rb`:

```ruby
config.active_job.queue_adapter = :delayed_job
```

See the [Rails Guide](https://guides.rubyonrails.org/active_job_basics.html#setting-the-backend) for more details.

### Protected Attributes

When using the `protected_attributes` gem, it must appear before `delayed_job` in your `Gemfile`. Otherwise you will see this error:

```
ActiveRecord::StatementInvalid: PG::NotNullViolation: ERROR:  null value in column "handler" violates not-null constraint
```

## Using Delayed Job in your Application

### Queuing Jobs

Call `.delay.method(params)` on any object and it will be processed in the background.

```ruby
# without delayed_job
@user.activate!(@device)

# with delayed_job
@user.delay.activate!(@device)
```

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

### Parameters

`#handle_asynchronously` and `#delay` take these parameters:

- `:priority` (number): lower numbers run first; default is 0 but can be reconfigured (see below)
- `:run_at` (Time): run the job after this time (probably in the future)
- `:queue` (string): named queue to put this job in, an alternative to priorities (see below)

These params can be Proc objects, allowing call-time evaluation of the value.

For example:

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

  class << self
    def call_a_class_method
      # Some other code
    end
    handle_asynchronously :call_a_class_method, :run_at => Proc.new { when_to_run }
  end

  attr_reader :how_important

  def call_an_instance_method
    # Some other code
  end
  handle_asynchronously :call_an_instance_method, :priority => Proc.new {|i| i.how_important }
end
```

To call a `handle_asynchronously`'d method without Delayed Job, add `_without_delay` to the method name.
For instance, if your original method was `foo`, then call `foo_without_delay`.

### Rails Mailers

Delayed Job uses special syntax for Rails Mailers.
Do not call the `.deliver` method when using `.delay`.

```ruby
# without delayed_job
Notifier.signup(@user).deliver

# with delayed_job
Notifier.delay.signup(@user)

# delayed_job running at a specific time
Notifier.delay(run_at: 5.minutes.from_now).signup(@user)

# when using parameters, the .with method must be called before the .delay method
Notifier.with(foo: 1, bar: 2).delay.signup(@user)
```

You may also wish to consider using
[Active Job with Action Mailer](https://edgeguides.rubyonrails.org/active_job_basics.html#action-mailer)
which provides convenient `.deliver_later` syntax that forwards to Delayed Job under-the-hood.

### Queues

Delayed Job supports assigning jobs to named queues. Each queue may be worked by a
separate pool of workers, which may then be scaled and controlled individually.

Jobs can be assigned to a queue by setting the `:queue` option:

```ruby
object.delay(queue: 'tracking').method

Delayed::Job.enqueue job, queue: 'tracking'

handle_asynchronously :tweet_later, queue: 'tweets'
```

You may configure a default priority for each queue (lower number = higher priority):

```ruby
Delayed::Worker.queue_attributes = {
  high_priority_queue: { priority: -10 },
  low_priority_queue: { priority: 10 }
}
```

To override the queue's default priority, pass `:priority` to the delay method:

```ruby
object.delay(queue: 'high_priority_queue', priority: 0).method
```

You can start processes to only work certain queues with the `queue` and `queues`
options (refer to "Running Jobs" section below.) Processes started without specifying
a queue will run jobs from **any** queue. To effectively have a process that runs
jobs where a queue is not specified, set a default queue name with
`Delayed::Worker.default_queue_name` and have the processes run that queue.

## Running Jobs

### Running as a Daemon Process

`script/delayed_job` starts a background daemon process which will continually work jobs.

To install this script, add `gem "daemons"` to your `Gemfile` then run `rails generate delayed_job`.

Then run the `start` command:

```
# Run a single worker as a background process
RAILS_ENV=production script/delayed_job start

# Run 4 workers in separate background child processes
RAILS_ENV=production script/delayed_job -n4 start
```

Each worker will check the database at least every 5 seconds.

### Stopping and Restarting

You may use `stop` and `restart` commands. These commands wait for each worker
to finish its current job before proceeding. 

```
# Shutdown all workers and exit
RAILS_ENV=production script/delayed_job stop

# Shutdown all workers and start a single new worker process
RAILS_ENV=production script/delayed_job restart

# Shutdown all workers and start 4 new worker processes
RAILS_ENV=production script/delayed_job -n4 restart
```

You must pass the same arguments to `restart` that you used when calling `start`.

You may also send `SIGTERM` to stop Delayed Job.

### Worker Queues and Pools

```
# Set the --queues option to work from a particular queue
RAILS_ENV=production script/delayed_job --queues=mailers,tasks start

# Use the --pool option to specify a worker pool. You can use this option multiple
# times to start different numbers of workers for different queues.
# The following command will start 1 worker for the tracking queue,
# 2 workers for the mailers and tasks queues, and 2 workers for any jobs:
RAILS_ENV=production script/delayed_job --pool=tracking --pool=mailers,tasks:2 --pool=*:2 start
```

### Exit On Complete Mode

```
# Run as a daemon and exit after working all available jobs
RAILS_ENV=production script/delayed_job start --exit-on-complete

# or to run in the foreground
RAILS_ENV=production script/delayed_job run --exit-on-complete
```

### Experimental: Forking Mode

The `script/delayed_job` process (described above) uses the
[Daemons](https://github.com/thuehlinger/daemons) gem which has several
undesirable behaviors when running inside a container (Docker, etc.):

* The parent process spawns a background child process then exits immediately,
which causes the container to shutdown.
* The worker processes are detached from the parent, which prevents logging to `STDOUT`.

The `--fork` option solves this by running workers in a foreground process tree.
When using `--fork` the `daemons` gem is not required.

```
# Run as a foreground process with 4 worker child processes.
RAILS_ENV=production script/delayed_job --fork -n4 start

# Forking mode supports queues and pools.
RAILS_ENV=production script/delayed_job --fork --pool=mailers,tasks:2 --pool=*:2 start
```

When spawning two or more workers (`-n2` or more), Delayed Job runs in "clustered" mode,
which borrows its code and logic from the [Puma webserver version 5+](https://puma.io/) ❤️.
In summary:

* The parent process spawns a foreground child worker process ("worker 0").
* Subsequent workers are forked from worker 0, using
[copy-on-write](https://en.wikipedia.org/wiki/Copy-on-write) forking.
* After a configurable timeout (default 1 hour), workers other than worker 0 are 
terminated and re-forked from worker 0, one-by-one. This "compacts"

Forking mode does not yet support the `restart`, `stop`, etc. script commands.
This is planned to be introduced in the future.
Use `SIGTERM` or `SIGINT` to allow workers to finish their current job then gracefully shutdown.

### Running via Rake

You may start a worker process using `rake jobs:work`.
You can exit the rake task with `CTRL-C`.

To run all available jobs and exit, use `rake jobs:workoff`.

Set the `QUEUES` or `POOLS` environment variable to work specific queues.

```
# Start a worker listening to all jobs
rake jobs:work

# Run 4 worker processes and exit when all jobs are finished
NUM_WORKERS=4 rake jobs:workoff

# Work all jobs from the "mailers" and "tasks" queues, then exit
NUM_WORKERS=4 QUEUES=mailers,tasks rake jobs:workoff

# You may also specify POOLS pipe-delimited
POOLS=mailers,tasks:2|tweets:1|*:2 rake jobs:workoff
```

Rake uses Forking Mode (see above).

### Development

In `development` environment, Delayed Job will automatically reload
your application code after each 100 jobs or when the queue finishes.
You should not need to restart Delayed Job each time you update your code.

## Advanced Topics

### Custom Jobs

Jobs are simple ruby objects with a method called `perform`.
Any object which responds to `perform` can be enqueued into the jobs table.
Job objects are serialized to YAML so that they can later be marshalled by the job runner.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end
end

Delayed::Job.enqueue NewsletterJob.new('lorem ipsum...', Customers.pluck(:email))
```

To override `Delayed::Worker.max_attempts` per-job, you can define a `max_attempts` instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def max_attempts
    3
  end
end
```

To override `Delayed::Worker.max_run_time` per-job, you may define a `max_run_time`
instance method in the job class.

**NOTE:** You may only set a `max_run_time` that is lower than `Delayed::Worker.max_run_time`.
Otherwise the lock on the job would expire and a second worker would start working the same in-progress job.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def max_run_time
    120 # seconds
  end
end
```

To override `Delayed::Worker.destroy_failed_jobs` per-job, you may define a `destroy_failed_jobs?`
instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def destroy_failed_jobs?
    false
  end
end
```

To override `Delayed::Worker.default_queue_name` per-job, you may define a `queue_name`
instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def queue_name
    'newsletter_queue'
  end
end
```

On error, the job is scheduled again in 5 seconds + N ** 4, where N is the number of attempts.
You may define a `reschedule_at` instance method to override this default behavior.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def reschedule_at(current_time, attempts)
    current_time + (attempts * 60).seconds
  end
end
```

### Hooks

You can define hooks on your job that will be called at different stages in the process:

**NOTE:** If you are using Active Job these hooks are **not** available to your jobs.
You will need to use Active Job's callbacks.
See the [Rails Guides](https://guides.rubyonrails.org/active_job_basics.html#callbacks) for details.

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

  def failure(job)
    page_sysadmin_in_the_middle_of_the_night
  end
end
```

### Gory Details

The library revolves around a `delayed_jobs` table which looks as follows:

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

On error, the job is scheduled again in 5 seconds + N ** 4, where N is the number of attempts or using the job's defined `reschedule_at` instance method.

The default `Delayed::Worker.max_attempts` is 25. After this, the job is either deleted (default), or left in the database with "failed_at" set.
With the default of 25 attempts, the last retry will be 20 days later, with the last interval being almost 100 hours.

The default `Delayed::Worker.max_run_time` is 4.hours. If your job takes longer than that, another computer could pick it up. It's up to you to
make sure your job doesn't exceed this time. You should set this to the longest time you think the job could take.

By default, it will delete failed jobs (and it always deletes successful jobs). If you want to keep failed jobs, set
`Delayed::Worker.destroy_failed_jobs = false`. The failed jobs will be marked with non-null failed_at.

By default all jobs are scheduled with `priority = 0`, which is top priority. You can change this by setting `Delayed::Worker.default_priority` to something else. Lower numbers have higher priority.

The default behavior is to read 5 jobs from the queue when finding an available job. You can configure this by setting `Delayed::Worker.read_ahead`.

By default all jobs will be queued without a named queue. A default named queue can be specified by using `Delayed::Worker.default_queue_name`.

If no jobs are found, the worker sleeps for the amount of time specified by the sleep delay option. Set `Delayed::Worker.sleep_delay = 60` for a 60 second sleep time.

It is possible to disable delayed jobs for testing purposes. Set `Delayed::Worker.delay_jobs = false` to execute all jobs realtime.

`Delayed::Worker.delay_jobs` may also be a `Proc` that decides whether to execute jobs inline on a per-job basis:

```ruby
Delayed::Worker.delay_jobs = ->(job) {
  job.queue != 'inline'
}
```

In Daemonized mode, `Delayed::Worker.raise_signal_exceptions = :term`
will cause the worker to raise a `SignalException` causing the running job to abort and be unlocked,
which makes the job available to other workers.
The default for this option is false.

In Forking mode, `Delayed::Worker.raise_signal_exceptions` set to any truthy
value will raise an exception only on `SIGTERM`. Exceptions are not raised on `SIGINT`.

Here is an example of changing job parameters in Rails:

```ruby
# config/initializers/delayed_job_config.rb
Delayed::Worker.destroy_failed_jobs = false
Delayed::Worker.sleep_delay = 60
Delayed::Worker.max_attempts = 3
Delayed::Worker.max_run_time = 5.minutes
Delayed::Worker.read_ahead = 10
Delayed::Worker.default_queue_name = 'default'
Delayed::Worker.delay_jobs = !Rails.env.test?
Delayed::Worker.raise_signal_exceptions = :term
Delayed::Worker.logger = Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))
```

### Cleaning up

You can invoke `rake jobs:clear` to delete all jobs in the queue.

### Having problems?

Good places to get help are:

* [Google Groups](https://groups.google.com/group/delayed_job) where you can join our mailing list.
* [StackOverflow](https://stackoverflow.com/questions/tagged/delayed-job)

### License & Attribution

Delayed Job is licensed under the [MIT License](LICENSE.txt).

Delayed Job was originally extracted from [Shopify](https://www.shopify.com/).

Code related to worker clustering is lovingly ❤️ borrowed from the [Puma webserver](https://puma.io/)
