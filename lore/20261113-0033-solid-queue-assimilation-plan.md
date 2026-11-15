# Assimilating Solid Queue ideas into multi-threaded delayed_job (plan)

Branches: `delayed_job` `multi-threaded`, `delayed_job_mongoid` `multi-threaded` (fork `johnnyshields/delayed_job_mongoid`).
Source studied: `alexandernicholson/solid_queue` (`main`, 43 commits ahead of `rails/solid_queue`), a MongoDB port of Solid Queue whose `docs/delayed_job/` plans move delayed_job features *into* Solid Queue. This plan goes the other way: Solid Queue's process runtime into delayed_job.

## Context

The biggest gap: when a worker process dies mid-job (OOM, `SIGKILL`, node loss), its jobs stay locked until `max_run_time` expires — 4 hours by default. Solid Queue recovers in minutes: the fork supervisor releases a dead fork's claims as soon as it exits, processes heartbeat and maintenance prunes dead ones, and death recovery caps crash loops. Solid Queue also bounds shutdown time, reports thread errors, and instruments everything.

Principles: no schema changes for existing backends; new hooks are optional with today's behaviour as fallback; anything that changes semantics is off by default.

## Phase 1 — process death and shutdown

1. **Release a dead child's locks immediately** (SQ: `ForkSupervisor#replace_fork` → `release_claimed_jobs_by`).
   - `Worker.default_name(prefix, pid = Process.pid)` so the forking parent can compute each thread's lock name from the child's pid and thread count.
   - On abnormal child exit, the parent reconnects (it disconnected in `before_fork`), releases the child's locks, and ignores DB errors (lock expiry stays the fallback).
   - Crash-loop guard: released jobs count as a failed attempt (`attempts += 1`, `last_error` = worker process exited with status …) via a new optional backend hook listing a name's locked jobs; fallback `clear_locks!`.
2. **Lock heartbeats** — off by default (SQ: `Registrable#heartbeat`, `process_alive_threshold`).
   - Every `lock_heartbeat_interval`, the dispatcher refreshes `locked_at` of its in-flight jobs via new optional hook `Job.touch_locks(names)`.
   - Reservation then treats locks older than `lock_timeout` (not `max_run_time`) as abandoned; existing `reserve(worker, max_run_time)` already takes the expiry age, so no schema change. Backends without the hook keep today's behaviour.
3. **Owner-guarded finish** (SQ: `claim_generation`, ownership-guarded finalization).
   - Optional hooks `Job#destroy_if_locked_by(name)` / `#unlock_if_locked_by(name)`, used by `Worker#run` / `reschedule` when present, so a stale worker whose lock expired can't delete or reschedule another worker's run. Needed once (2) shortens expiry.
4. **Shutdown timeout and `QUIT`** (SQ: `shutdown_timeout`, `Supervisor::Signals`).
   - `--shutdown-timeout=N` (default nil = wait for jobs, as today): after N seconds the dispatcher interrupts running jobs, releases their locks, exits. Parent escalates the same way.
   - `QUIT`: release locks and exit immediately.
5. **Children exit when the parent dies** (SQ: `supervisor_went_away?`).
   - Dispatcher compares `Process.ppid` each poll and stops gracefully when the parent is gone.
6. **Pidfile for `--fork` mode** with an already-running check (SQ: `Supervisor::Pidfile`).
   - Implemented as `Delayed::Pidfile`, opt-in via `--pid-file[=PATH]` / `PIDFILE` / `:pid_file`. Unlike SQ (which checks whether the pid in the file is alive), liveness is an `flock` on the file: released by the OS on any death, immune to pid reuse, and inherited by forked workers, so orphaned workers still block a restart. `Worker.after_fork` had to skip the pidfile when reopening inherited files (reopening dropped the lock).

## Phase 2 — observability

7. **`ActiveSupport::Notifications`** events `*.delayed_job` (`reserve`, `perform`, `error`, `failure`, `thread_error`, `start_process`, `stop_process`, `fork_replaced`, `locks_released`, `shutdown_timeout`) plus a log subscriber; existing `say` lines stay. (SQ: `SolidQueue.instrument`, `LogSubscriber`.)
   - Implemented (`Delayed.instrument`, `Delayed::LogSubscriber`, opt-in). Renamed `error`/`failure` to `attempt_failed`/`job_failed` (ActiveSupport's `LogSubscriber` has public level helpers named `error`, so a subscriber method `error` is never attached), `shutdown_timeout` to `interrupt` (also covers `QUIT`), and added `lock_lost`. Subscriber exceptions are logged and ignored, so a buggy subscriber can't fail or skip a job.
8. **`Delayed::Worker.on_thread_error`** for errors outside job handling (reservation, plugins, thread crashes). (SQ: `AppExecutor#handle_thread_error`.)
   - Implemented: `Worker.thread_error(error, info)` publishes `thread_error` and calls the handler (arity 1 or 2); reports reservation, heartbeat, worker-thread and dispatcher crashes (not signals/exits, and a re-raised thread crash once), failure hooks, and failed recovery in the forking parent. Handler errors are logged and ignored.
9. **`Delayed::Worker.silence_polling`** wraps each poll in `ActiveRecord::Base.logger.silence` — core version of the Mongoid `MongoSilencer` idea. (SQ: `with_polling_volume`.)
   - Implemented as backend hook `Job.silence_polling(&block)` (default: thread-local `ActiveRecord::Base.logger.silence(WARN)`), applied to reservation and lock-refresh queries only; `delayed_job_mongoid` overrides it for the Mongo driver logger.
10. **Live procline**, e.g. `delayed_job.0: 3/4 busy, queues=*`. (SQ: `procline`.)
    - Implemented: the dispatcher sets `$0` from its poll loop and shutdown wait (its own thread only, and only on change), adding `stopping, `/`quitting, `; launchers pass `:procline` (the process name incl. `--prefix`). `Worker#work_off` and bare dispatchers leave `$0` alone.

## Phase 2b — batched reservation (opt-in flag)

11. **Batched `reserve_batch` for MongoDB**, enabled with a flag.
    - Problem: today filling N idle threads takes N `find_one_and_update` round trips (only when N threads are idle at once: startup, backlog bursts; an idle poll stops at the first miss and is one query).
    - `delayed_job_mongoid`: `Delayed::Backend::Mongoid::Job.batch_reserve = true` (class attribute, default `false`), plus `batch_reserve_threshold` (default 4) below which it falls back to per-thread `reserve`. When enabled, `reserve_batch` takes 3 round trips regardless of N:
      1. `find` up to N candidate ids with `reserve`'s filters and sort;
      2. one `bulk_write` of N conditional `update_one`s, each on one candidate (`_id`, still unlocked or expired) setting `locked_by` to its thread's name;
      3. `find` `_id` in candidates and `locked_by` in our thread names to learn the winners (the bulk result only reports a total), paired back to their workers.
    - `delayed_job` core, dispatcher fix (backend-agnostic, always on): a partial batch is not proof the queue is empty — a batch backend may lose candidates to other processes. When a poll reserves some but fewer than the idle threads, poll again immediately; sleep `sleep_delay` only after a poll that reserves nothing. Costs one extra query when a queue genuinely drains.
    - Specs against MongoDB: distinct jobs per thread name, contention between two processes never double-locks, losers are retried immediately, threshold fallback, flag off = current behaviour.
    - Benchmark fill time at 4, 16 and 32 threads, flag on vs off, local and with added latency; keep (and document a recommendation) only if it pays off.
    - Implemented. Benchmark (median fill time, local MongoDB 8.0; off → on): 4 threads 4.3 → 4.0 ms, 16: 18.0 → 5.4 ms, 32: 33.3 → 6.9 ms; with +5 ms per round trip: 27.9 → 20.3, 115.8 → 21.9, 229.7 → 25.3 ms. Kept; recommended from 8 threads or with a remote database. Leftover locks under the idle workers' own names are reclaimed, as `reserve` does. The re-poll fix sends one extra query when a queue genuinely drains.
    - Postgres equivalent belongs in `delayed_job_active_record` (single `UPDATE … FROM (SELECT … LIMIT N FOR UPDATE SKIP LOCKED) RETURNING`, names by `row_number()`); out of scope here.

## Not adopting

- Concurrency limits, recurring tasks, batches, scheduled/ready split, delivery modes: need new tables/collections. delayed_job already gives at-least-once delivery with exclusive runs.
- Fork boot timeout: our parent boots the app before forking; children have almost no boot phase.
- Puma plugin, fiber pool (`--fibers`), queue wildcards and pausing: decided against.

## Rollout

- One commit per item on `delayed_job` `multi-threaded`; items 1–3 and 11 also on `delayed_job_mongoid` `multi-threaded` with specs against local MongoDB.
- Item 1 gets a real fork + `SIGKILL` spec; 2, 4, 5 get dispatcher specs.
- CHANGELOG, README and this lore file updated per item.
- Suggested start: 1, 4, 5 (job fate when processes die or are stopped).
