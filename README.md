**If you're viewing this at https://github.com/collectiveidea/delayed_job,
you're reading the documentation for the master branch.
[View documentation for the latest release
(4.1.10).](https://github.com/collectiveidea/delayed_job/tree/v4.1.10)**

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

Delayed Job was extracted from Shopify.

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

See the [Rails Guide](http://guides.rubyonrails.org/active_job_basics.html#setting-the-backend) for more details.

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

For production setups (systemd, Kubernetes, sizing, shutdown) see
[docs/deployment.md](docs/deployment.md); for what to watch, see
[docs/monitoring.md](docs/monitoring.md).

### Running as a Daemon Process

`script/delayed_job` starts a background daemon process which will continually work jobs.

To install this script, add `gem "daemons"` to your `Gemfile` then run `rails generate delayed_job`.

Then run the `start` command:

```
# Run a single worker as a background process
RAILS_ENV=production script/delayed_job start

# Run 4 worker processes (-n is short for --processes)
RAILS_ENV=production script/delayed_job -n4 start
RAILS_ENV=production script/delayed_job --processes=4 start
```

Each worker will check the database at least every second (`sleep_delay`, default 1).

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

You may also send `SIGTERM` to stop Delayed Job. In forking mode the parent
also treats `SIGHUP` (e.g. its terminal closing) as `SIGTERM`, and its worker
processes ignore `SIGHUP`, so the parent's pidfile stays until they have all
exited. A signal that arrives while the parent is still booting stops it before
it forks any worker process. Settings that every worker process would refuse
(e.g. `prefetch` above 20, or a `lock_timeout` set in an initializer that is
less than twice `--lock-heartbeat`) make the parent exit with an `ArgumentError`
before it forks.

### Worker Queues and Pools

```
# Set the --queues option to work from a particular queue
RAILS_ENV=production script/delayed_job --queues=mailers,tasks start

# Use the --pool option (queues:processes) to specify a worker pool. You can use
# this option multiple times to start different numbers of processes for different queues.
# The following command will start 1 process for the tracking queue,
# 2 processes for the mailers and tasks queues, and 2 processes for any jobs:
RAILS_ENV=production script/delayed_job --pool=tracking --pool=mailers,tasks:2 --pool=*:2 start
```

### Multi-Threaded Workers

Each worker process can run several jobs at once on separate threads, which
uses much less memory than running more processes and works well for IO-bound
jobs (HTTP calls, mailers, etc.). Use `-t`/`--threads` to set the number of
threads per process; total concurrency is processes × threads.

```
# 2 worker processes, each running 5 jobs concurrently (10 jobs at a time)
RAILS_ENV=production script/delayed_job --fork --processes=2 --threads=5 start

# --threads applies to every process, including pool processes:
# 3 processes (1 for mailers, 2 for any jobs), each with 4 threads
RAILS_ENV=production script/delayed_job --fork --pool=mailers:1 --pool=*:2 --threads=4 start
```

Every worker process, single- or multi-threaded, runs one `Delayed::Dispatcher`.
It reserves only as many jobs as there are idle threads and hands one to each,
so polling the database does not grow with the number of threads, and a job is
never locked while it waits for a thread. Each thread runs a `Delayed::Worker`
that locks jobs under its own name (e.g. `... pid:123 thread:2`).

Plugin callbacks: `:loop` wraps each poll and yields the `Delayed::Dispatcher`;
`:execute` wraps each worker thread's lifetime and yields its `Delayed::Worker`;
`:mold` (with `--mold`) wraps a mold process's life and yields its pid and
generation;
`:perform`, `:error` and `:failure` yield the `Delayed::Worker` running the job.

When using threads:

* Your job code must be thread-safe, and so must code Delayed Job calls from
  its threads: plugin callbacks, `ActiveSupport::Notifications` subscribers,
  `Delayed::Worker.on_thread_error` and your logger (Ruby's `Logger` is).
  Subscribers to `job_stuck` run on the lock heartbeat thread while the job
  runs: read only plain fields (`id`, `queue`) of its `:job`, and use
  `:job_name`.
* Don't call `Delayed::Worker.new` from a job: it would reset the settings and
  plugin callbacks of every worker in the process, so it raises.
* On JRuby, signal traps run on a thread of their own: with
  `raise_signal_exceptions`, the signal is raised in the main thread.
* The database connection pool must hold at least one connection per thread
  plus one for the dispatcher, and one more with lock heartbeats (`pool` in
  `config/database.yml`). A warning is logged if it is too small.
* On SQLite with Rails before 8.0, the `timeout` option of `database.yml`
  waits for a locked database without letting other threads run, so a thread
  waiting for the lock stops the thread holding it until the timeout raises
  "database is locked". Use Rails 8, or set
  `raw_connection.busy_handler_timeout = <ms>` on each connection.
* All threads of a process work the same queues, and every process runs the
  same number of threads.
* Under Rails, each job runs inside the Rails reloader (see Development below),
  which also resets per-job state such as `ActiveSupport::CurrentAttributes`
  and returns database connections to the pool after each job.
* On `SIGTERM`/`SIGINT`, running jobs finish before the process exits, as with
  single-threaded workers.

#### Prefetch

By default a thread that finishes a job waits for the next poll to get another.
With `--prefetch=N` (rake: `PREFETCH`, or `Delayed::Worker.prefetch`), each
thread also holds up to N jobs queued behind the one it runs, starts the next
as soon as it finishes, and the dispatcher tops its queue back up:

* `0` (default): jobs are reserved only for idle threads, one each.
* `1`: an idle thread gets 2 jobs (one runs, one waits); a busy thread whose
  queue is empty gets 1.
* `N`: up to N queued jobs per thread (at most 20).

The first jobs of each poll go to idle threads, so they start at once. A thread
takes its most urgent queued job next (lowest priority, then earliest `run_at`),
so a more urgent job reserved after its queue filled up doesn't wait behind the
others - only behind the job running.

```
RAILS_ENV=production script/delayed_job --fork --processes=2 --threads=5 --prefetch=2 start
```

With `--prefetch-dynamic` (`PREFETCH_DYNAMIC=1`, `Delayed::Worker.prefetch_dynamic`),
the queue depth adapts: it starts at 0 (idle threads only), grows by one level
after each poll that got every job it asked for (up to `--prefetch`), and drops
back to 0 after a poll that got fewer, as the queue ran dry. Jobs already queued
still run. At depth 0 only idle threads get jobs, so the depth grows again once
threads have worked through their queues and polls keep finding jobs for them.

A queued job waits behind its thread's current job, so prefetch suits many
short jobs; keep it at 0 for queues with long ones, or use `--prefetch-dynamic`
so jobs are only queued while there are plenty. Each job a thread holds is
locked under a slot name of its own, e.g. `... pid:123 thread:2 slot:1`. Also:

* On `SIGTERM`/`SIGINT`, queued jobs are released at once (unlocked, attempts
  unchanged) while running ones finish; a `jobs_released` event reports them.
* Without lock heartbeats, a job's lock lasts `max_run_time` from when it was
  reserved, queue time included. A queued job then runs with what is left of
  it as its time limit, so it stops before another worker could take it over;
  one whose lock expired while queued is released unstarted instead (a
  `jobs_released` event, `reason: 'lock expired in queue'`). With heartbeats,
  queued jobs' locks are refreshed and run with their full `max_run_time` -
  unless the heartbeat has stopped refreshing locks (it gave up after repeated
  failures, or a refresh has hung for `lock_timeout`): jobs started then are
  limited to what is left of their lock (`lock_timeout` from its last refresh),
  as without heartbeats.
* With heartbeats, a job that runs past its `max_run_time` without stopping
  (e.g. blocked in native code) also has the jobs queued behind it released
  (`reason: 'stuck job'`), and no more are queued on its thread until it ends.
* If a worker process dies, its queued jobs are recovered like its running ones,
  each counting a failed attempt.

With `--batch-reserve` (`BATCH_RESERVE=1`, `Delayed::Worker.batch_reserve`), a
worker reserves the jobs for all its free threads in one batch query, on
backends that implement one (`delayed_job_mongoid` does); others reserve one job
per thread as before. It is off by default.

Backend authors may override `Delayed::Job.reserve_batch(workers, max_run_time)`
to reserve jobs for several threads in one query, used when
`Delayed::Worker.batch_reserve` is set; each returned job must be
locked under the name of the worker it is paired with. A backend whose batch
may come back short while jobs are still available (it lost candidates to other
processes) also returns true from `Delayed::Job.partial_batch_may_leave_jobs?`:
the worker then polls again at once after a short batch. Otherwise (the default)
a short batch means the queue ran dry, and idle threads poll again after
`sleep_delay`.

### Exit On Complete Mode

```
# Run as a daemon and exit after working all available jobs
RAILS_ENV=production script/delayed_job start --exit-on-complete

# or to run in the foreground
RAILS_ENV=production script/delayed_job run --exit-on-complete
```

### Forking Mode

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

Forking mode does not support the `restart`, `stop`, etc. script commands: they
raise an `ArgumentError` (rather than starting another launcher). Stop it with a
signal instead (see Stopping and Restarting).
Use `SIGTERM` or `SIGINT` to allow workers to finish their current job then gracefully shutdown.
The parent forwards these signals to its worker processes, so sending them to the
parent alone (as `docker stop`, Kubernetes and systemd do) stops every worker.

#### Process titles

Each worker process keeps its title (as shown by `ps` and `top`) up to date
with its busy threads and queues, and whether it is stopping:

```
delayed_job.0: 3/4 busy, queues=mailers
delayed_job.1: stopping, 1/4 busy, queues=*
delayed_job.2: 4/4 busy, 3 queued, depth 1/2, queues=*   # with --prefetch=2 --prefetch-dynamic
delayed_job.3: promoting, 1/4 busy, queues=*            # with --mold: finishing its jobs
delayed_job.3: mold gen 2                               # with --mold
delayed_job.5 gen 2: 2/4 busy, queues=*                 # forked by that mold
```

#### Pidfile

With `--pid-file`, the parent process writes its pid to a file and refuses to
start while another launcher holds that file, e.g. to stop a second
`rake jobs:work` (a deploy script run twice, a cron job) from doubling your workers:

```
# tmp/pids/delayed_job.pid (or delayed_job.<identifier>.pid; see --pid-dir)
RAILS_ENV=production script/delayed_job --fork -n4 --pid-file start
RAILS_ENV=production script/delayed_job --fork -n4 --pid-file=/var/run/delayed_job.pid start
PIDFILE=1 rake jobs:work
PIDFILE=/var/run/delayed_job.pid rake jobs:work
```

A second launcher exits with `Delayed::AlreadyRunningError` before starting any
worker. The parent deletes the file when it exits. Whether a launcher runs is
decided by a lock on the file, not by the pid in it: a file left behind by a
SIGKILLed launcher, or holding a pid since reused by another process, doesn't
block a start. Worker processes inherit the lock, so workers orphaned by a
SIGKILLed parent keep a new launcher from starting until they finish their jobs
and exit. Daemon mode writes its own pidfiles in `--pid-dir` and doesn't take
`--pid-file`.

The same goes for processes your jobs start with `fork` (without `exec`): they
inherit the lock too, so a new launcher won't start until they exit. Processes
started with `spawn`, `system` or backticks run another program (`exec`) and
don't keep it, since Ruby opens files close-on-exec. A job that forks a
long-lived Ruby child can close the inherited pidfile in it:

```ruby
fork do
  ObjectSpace.each_object(File).select { |f| Delayed::Pidfile.lock_file?(f) }.each(&:close)
  # ...
end
```

#### Shutdown timeout and SIGQUIT

By default a stopping worker waits for its running jobs, however long they take.
Set a shutdown timeout to bound that, e.g. below your orchestrator's grace period
(Kubernetes' `terminationGracePeriodSeconds`, 30 seconds by default):

```
RAILS_ENV=production script/delayed_job --fork -n2 --shutdown-timeout=20 start
SHUTDOWN_TIMEOUT=20 rake jobs:work
# or in an initializer
Delayed::Worker.shutdown_timeout = 20
```

Jobs still running when it expires are interrupted with `Delayed::ShutdownInterrupt`
and released: unlocked, with their attempts and `run_at` unchanged, for another
worker to run right away. `SIGQUIT` does the same immediately. The forking parent
SIGKILLs any worker process still running 10 seconds after that.

`Delayed::ShutdownInterrupt` is not a `StandardError`, so `rescue => e` in a job
doesn't catch it. A released job runs again from the start, so jobs should be
safe to retry.

A job that never finishes within the shutdown timeout would come back on every
deploy without ever failing. To count each interruption as a failed attempt
instead (rescheduled with back-off, failing permanently after `max_attempts`):

```
RAILS_ENV=production script/delayed_job --fork --shutdown-timeout=20 --count-shutdown-interrupts start
COUNT_SHUTDOWN_INTERRUPTS=1 SHUTDOWN_TIMEOUT=20 rake jobs:work
Delayed::Worker.count_shutdown_interrupts = true
```

#### Lock heartbeats

A worker locks each job it runs. If the worker dies or hangs without its
process exiting (a frozen VM, a lost node, a deadlocked process), that lock is
only considered abandoned after `max_run_time`, 4 hours by default. Lock
heartbeats shorten that: each worker process refreshes the locks of its running
jobs every few seconds, and a lock that hasn't been refreshed for the lock
timeout counts as abandoned, so another worker picks the job up.

```
RAILS_ENV=production script/delayed_job --fork --lock-heartbeat=30 --lock-timeout=120 start
LOCK_HEARTBEAT=30 LOCK_TIMEOUT=120 rake jobs:work
# or in an initializer
Delayed::Worker.lock_heartbeat_interval = 30
Delayed::Worker.lock_timeout = 120 # default 300; at least twice the heartbeat
```

* Turn heartbeats on for **every** worker running the same jobs: a worker
  without them doesn't refresh its locks, so its long jobs would be taken over
  after the lock timeout.
* The backend must support them (`Delayed::Job.lock_heartbeats?`); otherwise
  Delayed Job logs a warning and locks expire after `max_run_time` as before.
* A worker whose lock was taken over doesn't overwrite the new owner's result:
  backends that implement `destroy_if_locked_by` and `save_if_locked_by` only
  finish, reschedule or fail a job while the worker still holds its lock.
* A job taken over from a worker that was only slow, not dead, runs twice.
  Choose a lock timeout well above the time a worker can stall.
* A job still running past its `max_run_time` (one its timeout can't
  interrupt, e.g. blocked in native code) no longer has its lock refreshed:
  an error is logged, and another worker may run it after the lock timeout -
  as without heartbeats, where its lock would expire after `max_run_time`.

#### When the parent process dies

If the forking parent is killed (e.g. with `SIGKILL`), its worker processes
notice within a second, stop polling, finish their running jobs (or interrupt
and release them after the shutdown timeout) and exit, instead of running on as
orphans.

#### Worker processes that die

When a worker process dies while running jobs (killed by the OOM killer or
`SIGKILL`, or exiting with a failure status), the parent process recovers its
jobs right away instead of leaving them locked until `max_run_time` expires.
Each counts as a failed attempt with a `Delayed::ProcessExitError`: it is
rescheduled with the usual back-off, or fails permanently after `max_attempts`,
so a job that keeps killing its worker eventually stops. `:error` and
`:failure` plugin callbacks and the job's `error` and `failure` hooks run as
for any failed attempt.

The dead worker process is then replaced, as is one that exits for any other
reason; the other worker processes carry on. (Delayed Job used to shut down
every worker process when one was `SIGKILL`ed.) A child process that dies
within 10 seconds of starting - e.g. running out of memory as it boots - is
replaced only after a delay that doubles with each such death in a row (1s,
2s, 4s, ... up to 60s), so a crash loop doesn't spin; a replacement that stays
up resets it.

If the database can't be reached at that moment, the jobs' locks expire after
`max_run_time` as before. Backends support this by implementing
`Delayed::Job.locked_jobs(worker_name)`; for backends without it, the locks are
only cleared. A process holds jobs under one lock name per thread (and per
prefetch slot), so `locked_jobs` and `clear_locks!` are also called with an
array of names, to list and clear them all in one query each.

#### Mold process (experimental)

Forked worker processes start out sharing the parent's memory copy-on-write,
but the parent has never run a job. As each child warms up (loading constants
lazily, filling caches, compiling with YJIT), its pages are copied, and after
a few days the children share little. With `--mold`, once a child process has
performed a number of jobs it is *promoted*: it stops like on `SIGTERM`
(queued jobs are released, running jobs finish) and becomes a **mold**, a
process that runs no jobs and only forks new child processes. Every child
process is then reforked from the mold, so they share its warmed memory.

```
# Promote after 1000 jobs (the default)
script/delayed_job --fork -n4 --mold start

# Promote again at each threshold (counted per child process since it started)
script/delayed_job --fork -n4 --mold=1000,5000,20000 start
MOLD=1000,5000,20000 NUM_PROCESSES=4 rake jobs:work

# or in an initializer
Delayed::Worker.mold = [1000, 5000, 20000] # true for [1000]
```

On Linux, the parent becomes a *child subreaper* (`prctl`, through the
`fiddle` gem), so the mold, and any child process it leaves behind, is
reparented to the parent:

```
delayed_job (parent)
 ├─ delayed_job.1: mold gen 1
 ├─ delayed_job.2 gen 1: 2/5 busy, queues=*      (forked by the mold)
 └─ delayed_job.3 gen 1: 5/5 busy, queues=*
```

(`ps` shows the children under the mold while it lives.) Elsewhere, or if
`fiddle` can't be loaded, a warning is logged and the mold is reparented to
init instead, with its children under it: process-tree tools such as
`pstree` or `pkill -P` won't find them under the parent, so use the process
group, the cgroup, or the `process_spawned` events (`:mold_pid`).

* The child process with the most jobs performed is promoted, preferring one
  with no job running, so promotion doesn't wait for a long job. Its running
  jobs finish first (interrupted and released after `--shutdown-timeout`, if
  set, never counting as a failed attempt). Meanwhile one process fewer works
  jobs; if it is still busy after 5 minutes, its slot is refilled. With
  `-n1`, set `--shutdown-timeout`, or no process works jobs until it finishes.
* Child processes are reforked about 10% at a time (at least one), idle ones
  first: each replacement is forked from the mold, and the process it replaces
  is stopped once it has started, so capacity doesn't drop. If a replacement
  dies before starting, the old process is kept. The previous mold is retired
  when the new one is ready: with a subreaper it exits at once (its children
  carry on); without, once its last child has exited.
* While reforking, up to N + 10% child processes run (each holding its
  database connections), plus the new mold and the old one: leave memory and
  connection headroom for that.
* `SIGURG` to the parent promotes a new mold at any time, without using up a
  threshold, and skipping any retry back-off. It is ignored (with a warning)
  while a promotion or refork is in progress: send it again after
  `mold_refork_completed`. Send it to the parent's pid only, not to the
  process group (`kill -URG -<pgid>`): each child process takes `SIGURG` as
  its own promotion, so they would all stop at once. Init processes that
  forward signals to the whole group do that: `dumb-init` (by default) and
  `tini -g`. `docker kill -s URG` and `kubectl exec ... kill -URG 1` are safe
  only when the parent is the container's PID 1.
* If the mold dies (e.g. killed by the OOM killer), its child processes carry
  on (adopted by the parent; without a subreaper they stop gracefully and are
  replaced), the parent forks new child processes itself, and a new mold is
  promoted, with a back-off growing after each failure in a row. A promotion
  that fails (the mold never gets ready) is retried the same way. A mold
  whose child processes keep failing to start (3 in a row; the log lists how
  each failed: an error exit usually means an `after_fork` hook raising, a
  boot timeout or signal a problem in the mold), that stops forking them,
  or that is stopped by a signal sent to it alone, is replaced the same way.
  After 5 failures in a row, promotion stops (`mold_disabled` event; child
  processes are forked from the parent) until `SIGURG` re-arms it.
* Before forking, the mold runs your `:mold` hooks, compacts its heap, and
  disconnects the backend before each fork. Use the hook to close clients
  the children shouldn't share (it's passed the mold's pid and generation).
  `before(:mold)` and the heap compaction must finish within 2 minutes of the
  promoted child exiting, or the promotion fails. `after(:mold)` doesn't run
  if the mold is killed (e.g. when replaced). If the parent dies, a hook
  still running gets 10 seconds before the mold exits regardless (a mold
  left running would keep the pidfile locked). An exception in a hook is
  reported to `on_thread_error` (context `Mold`) and fails the promotion:

  ```ruby
  class MoldPlugin < Delayed::Plugin
    callbacks do |lifecycle|
      lifecycle.before(:mold) { |_pid, _generation| Redis.current.disconnect! }
      lifecycle.after(:mold) { |_pid, _generation| puts 'Mold exiting' }
    end
  end
  ```
* Needs `fork` (not on JRuby or TruffleRuby), and runs only in forking mode
  (`--fork` or `rake jobs:work`). It can't be combined with `--identifier`,
  and is ignored (with a warning) with `--exit-on-complete` / `jobs:workoff`,
  which stop before any process could be promoted.
* With `--prefetch`, the promoted child's queued jobs are released (reason
  `promotion`); with lock heartbeats, the mold is forked only once its
  heartbeat thread has stopped. Both, and pools, work as without a mold.

The parent logs the total PSS (proportional set size, which counts shared
pages once) of its child processes and molds when a child is promoted and
again once every child process is reforked (`mold_activated` and
`mold_refork_completed` events, `:pss_mb`; Linux 4.14+). Check the gain
before relying on it.

**Containers.** A container's memory limit counts shared pages once (cgroup
`memory.current`, the `container_memory_working_set_bytes` metric), so the
gain shows there, while per-process RSS overstates usage. Size the limit for
the peak during a refork. On Kubernetes with cgroup v2, an OOM kill may take
down every process in the container (`memory.oom.group`), parent included,
rather than just the mold; check your Kubernetes version's behaviour (the
kubelet's `singleProcessOOMKill` setting).

**Operating it.** Enable it with `--mold` or `MOLD`; watch the `mold_*`
events (or log lines), the process titles and the PSS figures. It can't be
turned off at runtime: remove the option and restart, which is also the
rollback. Alert on repeated `mold_lost` or `mold_promotion_failed`, and on
`mold_disabled` (see docs/monitoring.md).

##### Fork safety

A mold is a process that has been running jobs, so it may hold state that
doesn't survive `fork`. Plain forking from the parent can be fine while
reforking isn't:

* **Threads** don't survive fork. Before its first fork, the mold logs a
  warning naming any thread still running (e.g. a client's background
  monitor). A thread holding a lock at fork time can leave the lock held
  forever in every child.
* **Connections** (Redis, HTTP pools, extra database clients) opened while
  running jobs are shared by every child unless closed in `before(:mold)`.
* **Fork-unsafe native libraries**: e.g. grpc (set
  `GRPC_ENABLE_FORK_SUPPORT`, or avoid it in jobs), libvips/ruby-vips, and
  others built on libgobject.

A job (or library) that leaves its process unsafe to fork can call
`Delayed::Worker.no_longer_fork_safe!`; that child process is then never
promoted. Try mold mode in staging first.

### Running via Rake

You may start a worker process using `rake jobs:work`.
You can exit the rake task with `CTRL-C`.

To run all available jobs and exit, use `rake jobs:workoff`.

Set the `QUEUES` or `POOLS` environment variable to work specific queues.

```
# Start a worker listening to all jobs
rake jobs:work

# Run 4 worker processes and exit when all jobs are finished
# (NUM_WORKERS is an alias of NUM_PROCESSES)
NUM_PROCESSES=4 rake jobs:workoff

# Work all jobs from the "mailers" and "tasks" queues, then exit
NUM_PROCESSES=4 QUEUES=mailers,tasks rake jobs:workoff

# You may also specify POOLS pipe-delimited
POOLS=mailers,tasks:2|tweets:1|*:2 rake jobs:workoff

# Run 2 worker processes with 5 threads each
NUM_PROCESSES=2 NUM_THREADS=5 rake jobs:work

# Refork worker processes from a mold after 1000 jobs (see Mold process)
MOLD=1000 NUM_PROCESSES=4 rake jobs:work

# Write tmp/pids/delayed_job.pid; refuse to start if another launcher holds it
PIDFILE=1 rake jobs:work
```

Rake uses Forking Mode (see above) under-the-hood.

### Development

In `development` environment, Delayed Job runs each job inside the Rails
reloader, so your application code is reloaded before a job when it has changed.
You should not need to restart Delayed Job each time you update your code.

With several threads (`--threads`), code is only reloaded once no thread is
running a job, so a running job never sees half-reloaded classes. While a job
runs, the other threads keep picking up jobs as usual - but once you change
code, the next job to start waits until the running ones finish, then runs on
the new code. So in development a long job holds up the others after each code
change; run a single thread there if that gets in your way.

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

### Silencing polling logs

An idle worker polls for jobs every `sleep_delay` seconds (and, with lock
heartbeats, refreshes its locks), which fills a debug-level SQL log. To keep
those queries out of the log:

```ruby
Delayed::Worker.silence_logging = true
```

or `--silence-logging` / `SILENCE_LOGGING=1`. Only the polling thread is
silenced, below `WARN`, while it polls: queries made by jobs, and by workers
finishing them, are logged as usual. The default backend hook silences
`ActiveRecord::Base.logger` (it needs an `ActiveSupport::Logger`); backends
logging elsewhere override `Delayed::Job.silence_logging(&block)`.

### Reporting errors outside of jobs

Job errors go through the `:error` lifecycle callback and the job's `error`
hook. Other errors - a failed reservation or lock heartbeat (e.g. the database
is down), a crashed worker thread or dispatcher, a failing `failure` hook, the
failed recovery of a dead worker process' jobs - are logged; to report them too:

```ruby
Delayed::Worker.on_thread_error = ->(error, info) do
  Sentry.capture_exception(error, extra: info) # info: :context, :dispatcher, :worker, :job
end
```

Errors raised by the handler are logged and ignored. Each such error also
publishes a `thread_error.delayed_job` event (see below).

### Instrumentation

Workers publish `ActiveSupport::Notifications` events named `<event>.delayed_job`,
grouped by what they are about:

* `process_started`, `process_stopped` (a worker process), `process_spawned`,
  `process_exited` (the forking parent's children);
* `jobs_reserved` (timed: a poll), `job_performed` (timed), `job_attempt_failed`,
  `job_failed`, `job_lock_lost`, `job_stuck`, `jobs_interrupted`,
  `jobs_released`;
* `thread_error` (see `on_thread_error` above).

[docs/monitoring.md](docs/monitoring.md#events) lists when each is published,
on which thread, and its payload. A subscriber that raises is logged and
ignored, so it can't fail or skip a job.

```ruby
ActiveSupport::Notifications.subscribe('job_failed.delayed_job') do |event|
  ErrorTracker.notify(event.payload[:error], job_id: event.payload[:job].id)
end
```

`Delayed::LogSubscriber` logs these events to `Delayed::Worker.logger`
(`jobs_reserved` and `job_performed` at debug level, with their durations).
Workers already log their activity, so it isn't attached by default:

```ruby
Delayed::LogSubscriber.attach_to :delayed_job
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

You may need to raise exceptions on SIGTERM signals, `Delayed::Worker.raise_signal_exceptions = :term` will cause the worker to raise a `SignalException` causing the running job to abort and be unlocked, which makes the job available to other workers. The default for this option is false. As with a shutdown timeout, the interrupted job is released with its attempts unchanged (unless `count_shutdown_interrupts` is set), and only the job's `perform` is interrupted: its hooks (`success`, `after`, ...) always run to the end, so a job that finished is never run again.

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
* [Google Groups](http://groups.google.com/group/delayed_job) where you can join our mailing list.
* [StackOverflow](http://stackoverflow.com/questions/tagged/delayed-job)
