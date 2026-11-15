Unreleased
==========
Breaking:
* Plugins: the `:loop` lifecycle callback now yields the `Delayed::Dispatcher` instead of a `Delayed::Worker`, and wraps each poll rather than each batch of up to 100 jobs.
* A forked worker process that dies (SIGKILL, OOM killer, crash) is replaced instead of making the parent shut down every worker process. Its jobs are recovered at once rather than left locked until `max_run_time`: each counts as a failed attempt with `Delayed::ProcessExitError` (rescheduled with back-off, or failed after `max_attempts`); a job whose payload can't be loaded gets the default back-off, and one that had already failed only has its lock cleared. A process that dies within 10 seconds of starting is replaced after a delay doubling with each such death in a row (1s up to 60s). Backend hook: `Delayed::Job.locked_jobs(names)`; it and `clear_locks!` take a name or an array of names, so all of a process' lock names are recovered in one query each (without `locked_jobs`, locks are only cleared).
* The command line and `rake jobs:work` share one set of rules (`Delayed::LaunchOptions`): invalid values raise an `ArgumentError` naming the option instead of falling back to a default (`--processes=x`, `--read-ahead=x`, `--min-priority=x`); `--processes=0`, `--min-priority` above `--max-priority`, `--processes` or `--queues` with `--pool`, and `--identifier` with `--pool` raise on the command line as in rake; seconds (`--sleep-delay`, `--shutdown-timeout`, `--lock-heartbeat`, `--lock-timeout`) take plain decimals such as `20` or `0.5` (`010` is ten; `0x10`, `1_0`, `1e3` are rejected); a pool's process count must be a whole number of 1 or more; `--fork` with `stop`, `restart`, `reload`, `zap` or `status` raises instead of starting another launcher; boolean environment variables treat blank, `0`, `f`, `false`, `n`, `no` and `off` as false (`QUIET=` meant quiet). Settings set in an initializer (`prefetch`, lock heartbeats) are validated by the forking parent before it forks.
* The default `sleep_delay` (how long an idle worker waits before polling again) is 1 second instead of 5, so an idle worker process polls the database once per second; set `--sleep-delay`, `SLEEP_DELAY` or `Delayed::Worker.sleep_delay` to poll less often.

Threads and polling:
* Multi-threaded workers: `-t`/`--threads=N` (`NUM_THREADS`) runs N jobs concurrently in each worker process, pool processes included, in forking and daemon modes. Every worker process runs a `Delayed::Dispatcher`, which owns the poll loop, signal handling and threads, and reserves jobs only for free threads through the new `Delayed::Job.reserve_batch` backend hook; `Delayed::Worker` only runs jobs (`Worker#start` runs itself through a single-threaded dispatcher; `Worker#work_off` is unchanged). If a backend says a short batch may leave jobs behind (`Delayed::Job.partial_batch_may_leave_jobs?`, default false), the worker polls again at once.
* Prefetch: `--prefetch=N` (`PREFETCH`, `Delayed::Worker.prefetch`; 0 to 20, default 0) lets each thread hold up to N jobs queued behind the one it runs, each locked under a slot name of its own (`... thread:2 slot:1`), and take the most urgent next. `--prefetch-dynamic` (`PREFETCH_DYNAMIC=1`) scales the queue depth from 0 up to N while polls get every job they ask for, and back to 0 when one gets fewer. Queued jobs are released on shutdown; without working lock heartbeats a queued job runs for what is left of its lock and is released unstarted if it expired; with heartbeats, jobs queued behind a stuck job are released.
* Batch reservation: `--batch-reserve` (`BATCH_RESERVE=1`, `Delayed::Worker.batch_reserve`; off by default) lets a backend that implements a batch `reserve_batch` (e.g. delayed_job_mongoid) reserve the jobs for all free threads in one query.
* Under Rails, each job runs inside the Rails reloader/executor; code is reloaded before a job when it has changed (instead of after each 100 jobs). With several threads, a reload waits until no thread is running a job.
* The number of worker processes is set with `-n`/`--processes=N` (`NUM_PROCESSES`); `--num-workers`, `--number_of_workers` (with a deprecation warning) and `NUM_WORKERS` still work. Launchers take `:processes` and `:threads` (`:worker_count` and `Launcher#worker_count` remain as aliases).
* Mold process (experimental): `--mold[=JOBS,...]` (`MOLD`, `Delayed::Worker.mold`; off by default) promotes a forked worker process that has performed JOBS jobs (default 1000; successive thresholds, comma-separated) to a mold, which runs no jobs and forks every worker process from then on, so they share its warmed memory copy-on-write. Worker processes are reforked about 10% at a time, idle ones first, each replacement starting before the process it replaces stops. `SIGURG` to the parent promotes a new mold. On Linux the parent is a child subreaper (adds a dependency on `fiddle`), so a mold dying doesn't stop its worker processes; a new mold is then promoted. Failed promotions are retried with back-off, and a mold whose worker processes fail to start is replaced. A `:mold` lifecycle hook (pid, generation) runs in the mold; `Delayed::Worker.no_longer_fork_safe!` keeps a worker process from being promoted; events `mold_promoted`, `mold_activated`, `mold_refork_completed`, `mold_retired` (`mold_activated` and `mold_refork_completed` with PSS totals), and `mold_lost`, `mold_promotion_failed`, `mold_disabled` for failures (promotion stops after 5 in a row, until `SIGURG`). Needs `fork`; forking mode only. A port of Puma's `mold_worker`, informed by Pitchfork.
* Before forking worker processes, the parent eager loads the Rails application and runs `Process.warmup` (or `GC.start` + `GC.compact`), so more memory is shared copy-on-write.

Stopping:
* Shutdown timeout: `--shutdown-timeout=N` (`SHUTDOWN_TIMEOUT`, `Delayed::Worker.shutdown_timeout`; default: wait) bounds how long a stopping worker waits; jobs still running are interrupted with `Delayed::ShutdownInterrupt` and released for another worker, attempts unchanged (`--count-shutdown-interrupts` counts them as failed attempts instead). `SIGQUIT` does the same at once. Only a job's `perform` is interrupted, never its hooks, so a finished job is never run again; a job interrupted by a signal (`raise_signal_exceptions`) is released the same way, and only the first `TERM`/`INT` raises.
* The forking parent forwards `TERM`/`INT`/`QUIT` to its worker processes (`docker stop`, Kubernetes, systemd), treats `SIGHUP` as `SIGTERM`, stops before forking if signalled while it boots, and with a shutdown timeout SIGKILLs workers still running 10 seconds after it. Worker processes stop gracefully when their parent goes away, and record a signal that arrives while they start up.
* Workers wake up immediately from their idle sleep when stopped.
* When the shutdown timeout's kill fires, the forking parent only sends `SIGKILL`; its run loop then reaps each worker process, recovering its jobs (`process_exited` published), and the parent exits with status 1. It could exit 0 ("exited gracefully") mid-recovery, leaving jobs locked until `max_run_time`. If the parent is still running 10s after the kill, it exits regardless.

Locks:
* Lock heartbeats (off by default): `--lock-heartbeat=N` (`LOCK_HEARTBEAT`, `Delayed::Worker.lock_heartbeat_interval`) refreshes the locks of running jobs every N seconds, and `--lock-timeout` (`LOCK_TIMEOUT`, default 300) is how old an unrefreshed lock must be for another worker to take its job over, instead of `max_run_time`. A job running past its `max_run_time` stops being refreshed, so a stuck job can't hold its lock forever. Backend hooks: `lock_heartbeats?`, `touch_locks(names)`.
* Owner-guarded finish: a worker only finishes, reschedules or fails a job while it still holds its lock, so a worker whose lock expired can't overwrite the result of the worker that took the job over. Backend hooks: `Job#destroy_if_locked_by(name)`, `#save_if_locked_by(name)`; shared examples `a delayed_job backend supporting lock heartbeats`.
* Pidfile for forking mode: `--pid-file[=PATH]` (`PIDFILE=1` or a path; launcher option `:pid_file`) makes a second launcher exit with `Delayed::AlreadyRunningError` while the first, or any of its worker processes, still runs. Liveness is decided by a lock on the file, so a stale file never blocks a start.

Monitoring:
* Instrumentation: `ActiveSupport::Notifications` events `process_started`, `process_stopped`, `process_spawned`, `process_exited`, `jobs_reserved`, `job_performed`, `job_attempt_failed`, `job_failed`, `job_lock_lost`, `job_stuck`, `jobs_interrupted`, `jobs_released` and `thread_error` (`<event>.delayed_job`; see docs/monitoring.md). Subscriber exceptions are logged and ignored. `Delayed::LogSubscriber` logs them (opt-in: `Delayed::LogSubscriber.attach_to :delayed_job`).
* `Delayed::Worker.on_thread_error` (taking the error and its info, the error, or nothing) is called with errors outside a job's own handling: failed reservations and lock heartbeats, crashed threads, failing `failure` hooks, failed recovery of a dead process' jobs.
* `Delayed::Worker.silence_logging = true` (`--silence-logging`, `SILENCE_LOGGING=1`) keeps polling and lock-refresh queries out of the log, on the polling thread only (backend hook `Delayed::Job.silence_logging(&block)`).
* Live process titles, e.g. `delayed_job.0: 3/4 busy, queues=mailers` or `delayed_job.1: stopping, 1/4 busy, queues=*`.

Fixes and smaller changes:
* `--fork` with `--pool`/`POOLS` and the default process count: the parent calls `Worker.before_fork` (children crashed in `after_fork`) and supervises its workers instead of exiting; `--identifier` with `-n > 1` no longer supervises a worker it never forked.
* `Worker#work_off` no longer stops early after a job failed to deserialize; such a job counts as failed.
* `Job#name` is `Unknown` for a handler that isn't valid YAML, instead of raising, and is recomputed after `reload`.
* `Delayed::Worker.reset` also resets `exit_on_complete`, `min_priority`, `max_priority` and `default_queue_name`. `Worker.after_fork` no longer reopens the pidfile.
* Shared backend examples cover `reserve_batch`, and `locked_jobs` and `clear_locks!` with an array of names.

4.2.0 - 2025-12-29
=======================
* Add dependencies for benchmark and logger which are moving out of stdlib.
* Pull ActiveJob adapter from rails into DJ for future rails release.
* Add Ruby 4.0 and Rails 8.1 to test matrix.

4.1.13 - 2024-11-08
=======================
* Enable Rails 8

4.1.12 - 2024-08-14
=======================
* Add missing require for extract_options
* Fix rails 7.2 ActiveSupport::ProxyObject deprecation
* Multiple contributors on current and legacy test suite improvements

4.1.12.rc1 - 2024-08-13
=======================
* Validating trusted publishing release
* Add missing require for extract_options
* Fix rails 7.2 ActiveSupport::ProxyObject deprecation
* Multiple contributors on current and legacy test suite improvements

4.1.11 - 2022-09-28
===================
* Fix missing require for Rails 7.0.3+

4.1.10 - 2022-01-17
===================
* Support for Rails 7.0. NOTE: If you are using Delayed Job independent of Rails, Active Support 7 has dropped classic dependency autoloading. You will need to add and setup zeitwerk for autoloading to continue working in ActiveSupport 7.

4.1.9 - 2020-12-09
==================
* Support for Rails 6.1
* Add support for parameterized mailers via delay call (#1121)

4.1.8 - 2019-08-16
==================
* Support for Rails 6.0.0

4.1.7 - 2019-06-20
==================
* Fix loading Delayed::PerformableMailer when ActionMailer isn't loaded yet

4.1.6 - 2019-06-19
==================
* Properly initialize ActionMailer outside railties (#1077)
* Fix Psych load_tags support (#1093)
* Replace REMOVED with FAILED in log message (#1048)
* Misc doc updates (#1052, #1074, #1064, #1063)

4.1.5 - 2018-04-13
==================
* Allow Rails 5.2

4.1.4 - 2017-12-29
==================
* Use `yaml_tag` instead of deprecated `yaml_as` (#996)
* Support ruby 2.5.0

4.1.3 - 2017-05-26
==================
* Don't mutate the options hash (#877)
* Log an error message when a deserialization error occurs (#894)
* Adding the queue name to the log output (#917)
* Don't include ClassMethods with MessageSending (#924)
* Fix YAML deserialization error if original object is soft-deleted (#947)
* Add support for Rails 5.1 (#982)

4.1.2 - 2016-05-16
==================
* Added Delayed::Worker.queue_attributes
* Limit what we require in ActiveSupport
* Fix pid file creation when there is no tmp directory
* Rails 5 support

4.1.1 - 2015-09-24
==================
* Fix shared specs for back-ends that reload objects

4.1.0 - 2015-09-22
==================
* Alter `Delayed::Command` to work with or without Rails
* Allow `Delayed::Worker.delay_jobs` configuration to be a proc
* Add ability to set destroy failed jobs on a per job basis
* Make `Delayed::Worker.new` idempotent
* Set quiet from the environment
* Rescue `Exception` instead of `StandardError` in worker
* Fix worker crash on serialization error

4.0.6 - 2014-12-22
==================
* Revert removing test files from the gem

4.0.5 - 2014-12-22
==================
* Support for Rails 4.2
* Allow user to override where DJ writes log output
* First attempt at automatic code reloading
* Clearer error message when ActiveRecord object no longer exists
* Various improvements to the README

4.0.4 - 2014-09-24
==================
* Fix using options passed into delayed_job command
* Add the ability to set a default queue for a custom job
* Add the ability to override the max_run_time on a custom job. MUST be lower than worker setting
* Psych YAML overrides are now exclusively used only when loading a job payload
* SLEEP_DELAY and READ_AHEAD can be set for the rake task
* Some updates for Rails 4.2 support

4.0.3 - 2014-09-04
==================
* Added --pools option to delayed_job command
* Removed a bunch of the Psych hacks
* Improved deserialization error reporting
* Misc bug fixes

4.0.2 - 2014-06-24
==================
* Add support for RSpec 3

4.0.1 - 2014-04-12
==================
* Update gemspec for Rails 4.1
* Make logger calls more universal
* Check that records are persisted? instead of new_record?

4.0.0 - 2013-07-30
==================
* Rails 4 compatibility
* Reverted threaded startup due to daemons incompatibilities
* Attempt to recover from job reservation errors

4.0.0.beta2 - 2013-05-28
========================
* Rails 4 compatibility
* Threaded startup script for faster multi-worker startup
* YAML compatibility changes
* Added jobs:check rake task

4.0.0.beta1 - 2013-03-02
========================
* Rails 4 compatibility

3.0.5 - 2013-01-28
==================
* Better job timeout error logging
* psych support for delayed_job_data_mapper deserialization
* User can configure the worker to raise a SignalException on TERM and/or INT
* Add the ability to run all available jobs and exit when complete

3.0.4 - 2012-11-09
==================
* Allow the app to specify a default queue name
* Capistrano script now allows user to specify the DJ command, allowing the user to add "bundle exec" if necessary
* Persisted record check is now more general

3.0.3 - 2012-05-25
==================
* Fix a bug where the worker would not respect the exit condition
* Properly handle sleep delay command line argument

3.0.2 - 2012-04-02
==================
* Fix deprecation warnings
* Raise ArgumentError if attempting to enqueue a performable method on an object that hasn't been persisted yet
* Allow the number of jobs read at a time to be configured from the command line using --read-ahead
* Allow custom logger to be configured through Delayed::Worker.logger
* Various documentation improvements

3.0.1 - 2012-01-24
==================
* Added RecordNotFound message to deserialization error
* Direct JRuby's yecht parser to syck extensions
* Updated psych extensions for better compatibility with ruby 1.9.2
* Updated syck extension for increased compatibility with class methods
* Test grooming

3.0.0 - 2011-12-30
==================
* New: Named queues
* New: Job/Worker lifecycle callbacks
* Change: daemons is no longer a runtime dependency
* Change: Active Record backend support is provided by a separate gem
* Change: Enqueue hook is called before jobs are saved so that they may be modified
* Fix problem deserializing models that use a custom primary key column
* Fix deserializing AR models when the object isn't in the default scope
* Fix hooks not getting called when delay_jobs is false

2.1.4 - 2011-02-11
==================
* Working around issues when psych is loaded, fixes issues with bundler 1.0.10 and Rails 3.0.4
* Added -p/--prefix option to help differentiate multiple delayed job workers on the same host.

2.1.3 - 2011-01-20
==================
* Revert worker contention fix due to regressions
* Added Delayed::Worker.delay_jobs flag to support running jobs immediately

2.1.2 - 2010-12-01
==================
* Remove contention between multiple workers by performing an update to lock a job before fetching it
* Job payloads may implement #max_attempts to control how many times it should be retried
* Fix for loading ActionMailer extension
* Added 'delayed_job_server_role' Capistrano variable to allow delayed_job to run on its own worker server
    set :delayed_job_server_role, :worker
* Fix `rake jobs:work` so it outputs to the console

2.1.1 - 2010-11-14
==================
* Fix issue with worker name not getting properly set when locking a job
* Fixes for YAML serialization

2.1.0 - 2010-11-14
==================
* Added enqueue, before, after, success, error, and failure. See the README
* Remove Merb support
* Remove all non Active Record backends into separate gems. See https://github.com/collectiveidea/delayed_job/wiki/Backends
* remove rails 2 support. delayed_job 2.1 will only support Rails 3
* New pure-YAML serialization
* Added Rails 3 railtie and generator
* Changed @@sleep_delay to self.class.sleep_delay to be consistent with other class variable usage
* Added --sleep-delay command line option

2.0.8 - Unreleased
==================
* Backport fix for deserialization errors that bring down the daemon

2.0.7 - 2011-02-10
==================
* Fixed missing generators and recipes for Rails 2.x

2.0.6 - 2011-01-20
==================
* Revert worker contention fix due to regressions

2.0.5 - 2010-12-01
==================
* Added #reschedule_at hook on payload to determine when the job should be rescheduled [backported from 2.1]
* Added --sleep-delay command line option [backported from 2.1]
* Added 'delayed_job_server_role' Capistrano variable to allow delayed_job to run on its own worker server
    set :delayed_job_server_role, :worker
* Changed AR backend to reserve jobs using an UPDATE query to reduce worker contention [backported from 2.1]

2.0.4 - 2010-11-14
==================
* Fix issue where dirty tracking prevented job from being properly unlocked
* Add delayed_job_args variable for Capistrano recipe to allow configuration of started workers (e.g. "-n 2 --max-priority 10")
* Added options to handle_asynchronously
* Added Delayed::Worker.default_priority
* Allow private methods to be delayed
* Fixes for Ruby 1.9
* Added -m command line option to start a monitor process
* normalize logging in worker
* Deprecate #send_later and #send_at in favor of new #delay method
* Added @#delay@ to Object that allows you to delay any method and pass options:
    options = {:priority => 19, :run_at => 5.minutes.from_now}
    UserMailer.delay(options).deliver_confirmation(@user)

2.0.3 - 2010-04-16
==================
* Fix initialization for Rails 2.x

2.0.2 - 2010-04-08
==================
* Fixes to Mongo Mapper backend [ "14be7a24":http://github.com/collectiveidea/delayed_job/commit/14be7a24, "dafd5f46":http://github.com/collectiveidea/delayed_job/commit/dafd5f46, "54d40913":http://github.com/collectiveidea/delayed_job/commit/54d40913 ]
* DataMapper backend performance improvements [ "93833cce":http://github.com/collectiveidea/delayed_job/commit/93833cce, "e9b1573e":http://github.com/collectiveidea/delayed_job/commit/e9b1573e, "37a16d11":http://github.com/collectiveidea/delayed_job/commit/37a16d11, "803f2bfa":http://github.com/collectiveidea/delayed_job/commit/803f2bfa ]
* Fixed Delayed::Command to create tmp/pids directory [ "8ec8ca41":http://github.com/collectiveidea/delayed_job/commit/8ec8ca41 ]
* Railtie to perform Rails 3 initialization [ "3e0fc41f":http://github.com/collectiveidea/delayed_job/commit/3e0fc41f ]
* Added on_permanent_failure hook [ "d2f14cd6":http://github.com/collectiveidea/delayed_job/commit/d2f14cd6 ]

2.0.1 - 2010-04-03
==================
* Bug fix for using ActiveRecord backend with daemon [martinbtt]

2.0.0 - 2010-04-03
==================
* Multiple backend support (See README for more details)
* Added MongoMapper backend [zbelzer, moneypools]
* Added DataMapper backend [lpetre]
* Reverse priority so the jobs table can be indexed. Lower numbers have higher priority. The default priority is 0, so increase it for jobs that are not important.
* Move most of the heavy lifting from Job to Worker (#work_off, #reschedule, #run, #min_priority, #max_priority, #max_run_time, #max_attempts, #worker_name) [albus522]
* Remove EvaledJob. Implement your own if you need this functionality.
* Only use Time.zone if it is set. Closes #20
* Fix for last_error recording when destroy_failed_jobs = false, max_attempts = 1
* Implemented worker name_prefix to maintain dynamic nature of pid detection
* Some Rails 3 compatibility fixes [fredwu]

1.8.5 - 2010-03-15
==================
* Set auto_flushing=true on Rails logger to fix logging in production
* Fix error message when trying to send_later on a method that doesn't exist
* Don't use rails_env in capistrano if it's not set. closes #22
* Delayed job should append to delayed_job.log not overwrite
* Version bump to 1.8.5
* fixing Time.now to be Time.zone.now if set to honor the app set local TimeZone
* Replaced @Worker::SLEEP@, @Job::MAX_ATTEMPTS@, and @Job::MAX_RUN_TIME@ with class methods that can be overridden.
