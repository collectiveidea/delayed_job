# Monitoring Delayed Job

The most important signal is **how long the oldest runnable job has been
waiting**: it rises whatever the cause - dead workers, a crash loop, a database
outage, stuck jobs or too little capacity. Alert on it first; use the signals
below to find out why.

## Failure scenarios

| Failure | What happens automatically | Signal |
|---|---|---|
| Launcher dies | Children finish their jobs and exit; nothing restarts the launcher | Supervisor; no workers polling |
| Child process dies | Its jobs count a failed attempt and are rescheduled; it is replaced | `process_exited` with a failure status |
| Child crash loop | Replaced after 1s, 2s, 4s… up to 60s | `process_exited` with `respawn_in > 0` |
| Worker thread crashes | Its child process stops, then as above | `thread_error` (`Worker thread`) |
| Database unreachable | Retried; after 10 failed polls in a row the child exits and is replaced | `thread_error` (`Reservation`) |
| Lock heartbeat failing | Retried; stops after 5 failures in a row | `thread_error` (`Lock heartbeat`) |
| Job stuck (native code) | With heartbeats, its lock lapses after `lock_timeout` and another worker runs it | `job_stuck`; later `job_lock_lost` |
| Job ran twice (lock taken over) | The later run's outcome is kept | `job_lock_lost` |
| Job fails | Retried with back-off; fails permanently after `max_attempts` | `job_attempt_failed`, `job_failed` |
| Shutdown overran | Running jobs interrupted and released | `jobs_interrupted`, `jobs_released` |
| Fork fails | Retried with back-off | `thread_error` (`Forking`; `Mold forking` when a mold failed and the parent forked it instead) |
| Mold lost (died, e.g. OOM-killed; broken; hung) | Its child processes carry on (with a subreaper); the parent forks new ones itself, and a new mold is promoted with back-off | `mold_lost` |
| Mold promotion failing | Retried with back-off doubling per failure in a row | `mold_promotion_failed` |

## Errors outside jobs

```ruby
# config/initializers/delayed_job.rb
Delayed::Worker.on_thread_error = ->(error, info) do
  Sentry.capture_exception(error, tags: { dj_context: info[:context] }, extra: info.except(:job))
end
```

`info[:context]` is one of `Reservation`, `Lock heartbeat`, `Worker thread`,
`Dispatcher`, `Failure hook`, `Recovering jobs`, `Releasing interrupted jobs`,
`Forking`, and with `--mold`, `Mold` (an error in the mold, e.g. in a
`:mold` hook; reported from the mold process), `Mold forking` and
`Mold supervisor`. Report job errors through an `:error` lifecycle callback or the
`job_attempt_failed` event.

## Events

Workers publish `ActiveSupport::Notifications` events named
`<event>.delayed_job`. Names are `<subject>_<what happened>`: `job_*` for one
job, `jobs_*` for several at once, `process_*` for a worker process, and
`mold_*` for a mold process, and `thread_error` for errors outside jobs. Timed events (marked ⏱) cover the work
they describe and carry `:exception` when it raised.

| Event | When | Published by | Payload |
|---|---|---|---|
| `process_started` | A worker process starts its dispatcher | Worker process | `:dispatcher` (name), `:pid`, `:threads`, `:queues`, `:prefetch`, `:prefetch_dynamic` |
| `process_stopped` | Its dispatcher stopped | Worker process | as `process_started`, plus `:error` (what stopped it, or nil) |
| `process_spawned` | The forking parent (or its mold) forked a worker process | Launcher (parent) | `:worker`, `:pid`, `:replaces_pid` (pid of the process it replaces, or nil), `:delay` (seconds waited before forking it), `:mold_pid` (when a mold forked it), `:generation` (with a mold) |
| `process_exited` | A forked worker process exited | Launcher (parent) | `:worker`, `:pid`, `:status` (`Process::Status`, or `Delayed::ReportedStatus` as reported by a mold; both unknown if the mold died first), `:uptime` (seconds; an exit status of `Delayed::ExitStatus::PROMOTION_FAILED` or `JOBS_STUCK` isn't a crash, see `lib/delayed/exit_status.rb`), `:respawn_in` (seconds until it is replaced: 0 at once, more after quick deaths; nil when not replaced, or when promoted to mold: replaced once its mold is ready) |
| `mold_promoted` | A worker process is promoted to mold (see README, Mold process) | Launcher (parent) | `:worker`, `:pid`, `:jobs` (performed), `:trigger` (`:threshold`, `:signal`, or `:mold_lost` when replacing a mold that died) |
| `mold_activated` | A mold is ready; worker processes are reforked from it | Launcher (parent) | `:pid`, `:generation` (1 for the first mold), `:pss_mb` (total PSS of the processes, Linux), `:subreaper` (false: a mold's child processes stop if it dies) |
| `mold_refork_completed` | Every worker process is reforked from the active mold | Launcher (parent) | `:pid`, `:generation`, `:pss_mb`, `:pss_mb_before` (at activation) |
| `mold_retired` | The previous mold stops forking (and exits) | Launcher (parent) | `:pid` |
| `mold_lost` | The active mold died, was broken (child processes it forked kept failing to start) or hung | Launcher (parent) | `:pid`, `:generation`, `:reason` (`:exited`, `:broken`, `:hung`, `:stopped` by a signal sent to it alone), `:retry_in` (seconds until a new mold is promoted; nil once promotion is disabled) |
| `mold_promotion_failed` | A promotion produced no mold | Launcher (parent) | `:pid` (promoted child), `:mold_pid` (if one was forked), `:trigger`, `:reason` (`:child_exited`, `:mold_exited`, `:timeout`), `:retry_in` (nil once promotion is disabled) |
| `mold_disabled` | Promotion stopped after 5 failures (or lost molds) in a row; child processes are forked from the parent until `SIGURG` to the parent re-arms it | Launcher (parent) | `:failures` |
| `jobs_reserved` ⏱ | A poll for jobs (one query, or one per free slot) | Dispatcher thread | `:dispatcher`, `:requested` (free slots: idle threads, plus queue slots with prefetch), `:depth` (prefetch queue depth), `:reserved` |
| `job_performed` ⏱ | A job ran (successfully or not) | Worker thread | `:job`, `:worker`, `:success` (absent when interrupted: see `:exception`) |
| `job_attempt_failed` | A job raised; it is rescheduled or, after `max_attempts`, failed | Worker thread (launcher for a dead process' jobs) | `:job`, `:worker`, `:error`, `:attempts` (including this one) |
| `job_failed` | A job failed permanently | Worker thread (or launcher) | `:job`, `:worker`, `:error` |
| `job_lock_lost` | A job finished, was rescheduled or failed after its lock was taken over: this run's outcome is discarded | Worker thread | `:job`, `:worker`, `:outcome` (`finished`, `rescheduled`, `failed`) |
| `job_stuck` | A job ran past its `max_run_time` without stopping (e.g. blocked in native code); with heartbeats its lock is no longer refreshed | Lock heartbeat thread (read only plain fields of `:job`) | `:job`, `:job_name`, `:worker`, `:max_run_time`, `:lock_timeout` |
| `jobs_interrupted` | Running jobs were interrupted by the shutdown timeout or `SIGQUIT` | Dispatcher thread | `:dispatcher`, `:jobs` (count), `:reason` |
| `jobs_released` | Jobs were unlocked for other workers | Worker or dispatcher thread; launcher for a dead process | `:workers` (lock names), `:count`, `:reason` (below); `:error` for `process exit` |
| `thread_error` | An error outside a job's own handling (see below) | Any | `:error`, `:context`, and `:dispatcher`, `:worker`, `:job` where known |

`jobs_released` reasons: `shutdown` (interrupted, or queued and never
started), `promotion` (queued when its worker process was promoted to mold), `process exit` (recovered from a dead worker process, each counting
a failed attempt), `lock expired in queue` (with prefetch, its lock expired
while it waited) and `stuck job` (queued behind a job past its
`max_run_time`).

Events are published on the thread doing the work. A subscriber that raises is
logged and ignored, so it can't fail or skip a job. Subscribe in an
initializer, so that worker processes inherit it.

## Metrics from events

```ruby
ActiveSupport::Notifications.subscribe(/\.delayed_job\z/) do |event|
  name = event.name.delete_suffix('.delayed_job')
  p = event.payload
  case name
  when 'job_performed'
    METRICS.timing('dj.job_performed', event.duration, tags: ["job:#{p[:job].name}", "success:#{p[:success]}"])
  when 'job_attempt_failed', 'job_failed', 'job_lock_lost'
    METRICS.increment("dj.#{name}", tags: ["job:#{p[:job].name}"])
  when 'job_stuck'
    METRICS.increment('dj.job_stuck', tags: ["job:#{p[:job_name]}"])
  when 'thread_error'
    METRICS.increment('dj.thread_error', tags: ["context:#{p[:context]}"])
  when 'process_exited'
    METRICS.increment('dj.process_exited', tags: ["clean:#{p[:status].success?}", "delayed:#{p[:respawn_in].to_i > 0}"])
  when 'jobs_interrupted', 'jobs_released'
    METRICS.increment("dj.#{name}", p[:jobs] || p[:count], tags: ["reason:#{p[:reason]}"])
  when 'process_spawned'
    METRICS.increment('dj.process_spawned')
  when 'mold_promoted', 'mold_lost', 'mold_promotion_failed', 'mold_disabled'
    METRICS.increment("dj.#{name}", tags: ["reason:#{p[:reason] || p[:trigger]}"])
  when 'mold_activated', 'mold_refork_completed'
    METRICS.gauge('dj.mold_pss_mb', p[:pss_mb]) if p[:pss_mb]
  end
end
```

`METRICS` stands for your metrics client (StatsD, Datadog, Prometheus...). To
log every event instead, attach the bundled subscriber:
`Delayed::LogSubscriber.attach_to :delayed_job`.

## Queue health from the database

Collect these from outside the workers (cron or a metrics agent), so they keep
reporting when every worker is down:

```ruby
now = Delayed::Job.db_time_now
waiting = Delayed::Job.where(failed_at: nil, locked_at: nil).where('run_at <= ?', now)
expiry = Delayed::Worker.lock_expiry # lock_timeout with working heartbeats, else max_run_time

METRICS.gauge('dj.backlog', waiting.count)
METRICS.gauge('dj.oldest_waiting_seconds', (now - (waiting.minimum(:run_at) || now)).to_i)
METRICS.gauge('dj.held', Delayed::Job.where(failed_at: nil).where.not(locked_at: nil).count)
METRICS.gauge('dj.failed', Delayed::Job.where.not(failed_at: nil).count)
METRICS.gauge('dj.stale_locks', Delayed::Job.where(failed_at: nil).where('locked_at < ?', now - expiry).count)
```

Group by `queue` if you use pools. With Mongoid, use the equivalent criteria.

`held` counts locked jobs: those running and, with `--prefetch`, those queued
behind them. The database can't tell the two apart; the number running is the
`busy` count in each process's title (see below), and the rest are queued.

## Alerts

| Alert | Condition |
|---|---|
| Queue stalled | `oldest_waiting_seconds` above your latency target, per queue |
| No workers | No launcher process, or no `job_performed`/`jobs_reserved` events for 5 minutes while the backlog is > 0 |
| Crash loop | `process_exited` with `respawn_in > 0` for 10 minutes |
| Infrastructure | Any `thread_error` with context `Reservation`, `Lock heartbeat`, `Forking`, `Mold forking`, `Mold supervisor` or `Recovering jobs` |
| Mold unhealthy | `mold_lost` or `mold_promotion_failed` more than 3 times an hour, or any `mold_disabled` (check fork safety and memory limits; see the README) |
| Stuck jobs | Any `job_stuck`, or `stale_locks > 0` |
| Duplicate runs | Any `job_lock_lost` (raise `LOCK_TIMEOUT`) |
| Failures | Rise in the `job_failed` rate or the `failed` count |
| Slow shutdowns | `jobs_interrupted` outside deploys |

## On the host

`ps` shows each child process's state live, e.g.
`delayed_job.0: 3/4 busy, queues=mail` or `delayed_job.1: stopping, 1/4 busy, queues=*`.
A child stuck at full capacity while its queue grows means long or stuck jobs.

The launcher logs every child process start and exit, and each quick death
before a delayed respawn: `Child process delayed_job.2 (pid 812) died 0.4s
after starting (3 time(s) in a row); waiting 4s before replacing it`.

## Liveness probes

The default probe (process alive) is usually enough with the queue alerts
above. For a deeper per-process probe, touch a file on `jobs_reserved` and
`job_performed` events and check its age - but a process whose threads are all busy with long
jobs doesn't poll, so allow more than your longest normal job.
