# Deploying Delayed Job

## Process model

```
supervisor (systemd / Kubernetes / ...)
 └─ launcher (parent)          reaps children, recovers their jobs, respawns them
     └─ child process × N      --processes / pools
         ├─ dispatcher thread  polls for jobs, hands them out, handles signals
         ├─ worker threads × T --threads; each runs one job at a time
         └─ heartbeat thread   with --lock-heartbeat
```

With `--mold` (experimental), a child process is promoted to a mold that forks
the child processes from then on (see the README, Mold process). On Linux the
launcher is a child subreaper, so the mold, and children it leaves behind,
are reparented to it:

```
launcher (parent)
 ├─ mold                       runs no jobs; forks children, reports their exits
 └─ child process × N          forked by the mold
```

Leave headroom for a refork: up to N + 10% children plus two molds run at
once. Read the README's Fork safety section before enabling it.

Concurrency is processes × threads. Nothing restarts the launcher itself:
run it under a supervisor.

## Starting workers

Run in the foreground under your supervisor:

```sh
NUM_PROCESSES=4 NUM_THREADS=5 bundle exec rake jobs:work
# or
bin/delayed_job --fork --processes=4 --threads=5 start
```

Avoid daemon mode (`bin/delayed_job -d start`) under systemd or in containers:
daemonized workers are detached from any supervisor, and nothing restarts them
or stops them if they're orphaned.

## Sizing

- **Threads** suit IO-bound jobs (HTTP calls, mail, database). On CRuby only
  one thread runs Ruby code at a time, so CPU-bound jobs need more processes,
  not more threads.
- **Database connection pool**: at least threads + 1 per process, + 1 more
  with lock heartbeats. A warning is logged if it is too small.
- **Memory**: each process holds its own copy of the app; the parent eager
  loads and compacts the heap before forking, so much of it is shared
  copy-on-write. Children diverge as they warm up; `--mold` reforks them from
  a warmed child to share memory again. Measure it: sum `Pss` from
  `/proc/<pid>/smaps_rollup` across the children before and after a refork.
- **Queues**: all threads of a process work the same queues. Use pools to give
  queues their own processes: `--pool=mailers:2 --pool=*:4` or
  `POOLS='mailers:2|*:4'`.

## Configuration

| Setting | CLI | Rake env | Default |
|---|---|---|---|
| Processes | `-n`, `--processes` | `NUM_PROCESSES` | 1 |
| Threads per process | `-t`, `--threads` | `NUM_THREADS` | 1 |
| Jobs queued per thread (prefetch) | `--prefetch`, `--prefetch-dynamic` | `PREFETCH`, `PREFETCH_DYNAMIC=1` | 0, off |
| Batch reservation (backend support) | `--batch-reserve` | `BATCH_RESERVE=1` | off |
| Mold process (experimental) | `--mold[=JOBS,...]` | `MOLD=1000,...` or `MOLD=true` | off |
| Queues / pools | `--queues`, `--pool` | `QUEUES`, `POOLS` | all |
| Idle poll interval (s) | `--sleep-delay` | `SLEEP_DELAY` | 1 |
| Shutdown timeout (s) | `--shutdown-timeout` | `SHUTDOWN_TIMEOUT` | none (wait) |
| Count interrupted jobs as failed | `--count-shutdown-interrupts` | `COUNT_SHUTDOWN_INTERRUPTS=1` | off |
| Lock heartbeat (s) | `--lock-heartbeat` | `LOCK_HEARTBEAT` | off |
| Lock timeout (s) | `--lock-timeout` | `LOCK_TIMEOUT` | 300 |
| Pidfile | `--pid-file[=PATH]` | `PIDFILE=1` or a path | off |
| Quiet polling queries | `--silence-logging` | `SILENCE_LOGGING=1` | off |

All but processes, threads, pools and the pidfile are also
`Delayed::Worker` settings (e.g. `Delayed::Worker.shutdown_timeout = 20`) for an
initializer; command-line options and environment variables override them.

## Stopping and deploying

| Signal (to the launcher) | Effect |
|---|---|
| `TERM`, `INT` | Stop polling; let running jobs finish (up to the shutdown timeout, then interrupt and release them); exit |
| `QUIT` | Interrupt and release running jobs at once; exit |
| `HUP` | Forking mode: as `TERM` (worker processes ignore `HUP` itself) |

The launcher forwards signals to its children. Released jobs are unlocked with
attempts unchanged and run again from the start elsewhere, so **jobs must be
safe to retry**. With `COUNT_SHUTDOWN_INTERRUPTS=1` an interruption counts as a
failed attempt, so a job that never fits in the timeout eventually fails
instead of coming back on every deploy.

**Always set a shutdown timeout below your platform's kill deadline.** If the
platform SIGKILLs the launcher, nothing recovers its children's jobs: they stay
locked until `max_run_time` (4 hours by default), or `lock_timeout` with
heartbeats. Leave about 15 seconds: the launcher SIGKILLs children still
running 10 seconds after the timeout.

## Crashes and recovery

- **A child process dies** (OOM killer, crash): the launcher counts a failed
  attempt for each job it was running and reschedules them with back-off, then
  forks a replacement. A child that dies within 10 seconds of starting is
  replaced after 1s, 2s, 4s… up to 60s, so a crash loop can't spin.
- **A worker thread crashes**: its whole child process stops and is handled as
  above. Threads are never restarted individually.
- **The launcher dies**: children notice within a second, finish their jobs
  and exit. Your supervisor restarts the launcher.
- **A worker hangs or its host disappears**: its jobs stay locked until
  `max_run_time`. Enable **lock heartbeats** to shorten that to
  `lock_timeout`: e.g. `LOCK_HEARTBEAT=30 LOCK_TIMEOUT=120`. Enable them on
  every worker sharing the jobs. A job taken over from a worker that was only
  slow runs twice, so keep `LOCK_TIMEOUT` well above any stall you expect.

## Backend support

Recovery of a dead child's jobs, lock heartbeats and owner-guarded writes need
backend support. `delayed_job_mongoid` (multi-threaded branch) has all of
them. Backends without them still work: locks of dead workers are cleared
instead of recovered, and heartbeats are disabled with a warning.

## systemd

```ini
[Service]
WorkingDirectory=/srv/app/current
Environment=RAILS_ENV=production NUM_PROCESSES=4 NUM_THREADS=5
Environment=SHUTDOWN_TIMEOUT=60 LOCK_HEARTBEAT=30 LOCK_TIMEOUT=120 PIDFILE=1
ExecStart=/usr/bin/env bundle exec rake jobs:work
Restart=always
RestartSec=5
KillMode=mixed      # TERM to the launcher, which forwards it to its children
TimeoutStopSec=80   # > SHUTDOWN_TIMEOUT + 15
```

## Kubernetes

```yaml
spec:
  terminationGracePeriodSeconds: 80   # > SHUTDOWN_TIMEOUT + 15
  containers:
    - name: worker
      command: ["bundle", "exec", "rake", "jobs:work"]
      env:
        - { name: NUM_PROCESSES, value: "2" }
        - { name: NUM_THREADS, value: "5" }
        - { name: SHUTDOWN_TIMEOUT, value: "60" }
        - { name: LOCK_HEARTBEAT, value: "30" }
        - { name: LOCK_TIMEOUT, value: "120" }
```

Run the launcher as the container's main process (PID 1, or behind `tini`) so
it receives `SIGTERM`. Scale with replicas rather than very large process
counts per pod.

## Development

For code reloading with threads, see Development in the README. See [monitoring.md](monitoring.md) for what to watch in production.
