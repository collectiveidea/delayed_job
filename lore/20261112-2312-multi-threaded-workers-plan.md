# Multi-threaded workers (plan)

Branch: `multi-threaded` (from `forking-launcher`)


## Context
Today each delayed_job worker process (forked by `Launcher::Forking` or daemonized by `Launcher::Daemonized`) runs one `Delayed::Worker` loop, so concurrency = number of processes. Goal: each process also runs **N job threads** (cheaper than more processes for IO-bound jobs), keeping the multi-process model as-is. Total concurrency = processes × threads. Default threads = 1 → existing behaviour untouched.

Architecture (chosen after red-team): **demand-driven dispatcher per process**. One dispatcher reserves only as many jobs as there are idle threads, then hands each to a thread. That cuts idle DB polling from N queries per process per `sleep_delay` to 1, and never leaves a job locked while it waits for a thread.

Worktree: `/mnt/c/workspace/delayed_job-multi-threaded`, branch `multi-threaded` (created from `forking-launcher` @ `17c923f`; the main checkout's pending diff is line-ending-only).

## Constraints from exploration
- `Worker#initialize` writes `queues`/`min_priority`/`max_priority`/`read_ahead`/`sleep_delay`/`exit_on_complete` into **class-level** cattrs, which backends (incl. external `delayed_job_active_record`) read globally. ⇒ One queue config per process; pools stay per-process, threads sit inside each pool process.
- `find_available(worker_name, …)` also returns jobs *already locked by `worker_name`* (crash recovery). ⇒ Each thread must lock under its **own unique name**, or the dispatcher would re-fetch jobs that are already running.
- `delayed_job_active_record#reserve` uses an optimized single-statement atomic `UPDATE … LIMIT 1` reserve. ⇒ Batch reserve must go through `reserve`, not a generic find-then-lock.
- CI: Ruby 2.6+ incl. **JRuby** (true parallelism), Rails 5.2+ (`Rails.application.reloader`/`executor` always available). Rubocop `TargetRubyVersion 2.1`; guard `report_on_exception` with `respond_to?`.
- `Worker.new` resets the global lifecycle (`setup_lifecycle`) ⇒ build all worker objects in the main thread before any thread starts.

## Design

### 1. Backend hook — `lib/delayed/backend/base.rb`
`ClassMethods#reserve_batch(workers, max_run_time = Worker.max_run_time)` → `[[worker, job], …]`.
Default: for each worker, `reserve(worker, max_run_time)`; stop at the first `nil` (queue empty → no wasted queries). Because each call uses that thread's name, the existing optimized backend paths and lock semantics carry over. Backends can override later with a true single-query batch, but must lock each job under its worker's name (documented).

### 2. `Delayed::Worker` refactor — `lib/delayed/worker.rb`
- Split `start` → `trap_signals` + `work_loop` (public); `start` = both, behaviour unchanged.
- Split `reserve_and_run_one_job` → `reserve_job` (exists) + `perform_job(job)` (runs `:perform` lifecycle + `run`). Behaviour unchanged.
- Interruptible idle sleep: replace `sleep(sleep_delay)` with a Mutex+ConditionVariable `wait(sleep_delay)`; `stop` signals it ⇒ prompt shutdown (benefits single-thread mode too).
- `attr_accessor :thread_index`; default `name` appends ` thread:#{i}` when set.

### 3. New `Delayed::ThreadedWorker < Delayed::Worker` — `lib/delayed/threaded_worker.rb`
Subclassing reuses `start`, signal traps, `:execute`/`:loop` lifecycle, `say`, `exit_on_complete`, sleep/reload handling.
- `initialize(options, thread_count)`: `super`; builds `thread_count` child `Worker`s (`thread_index` i, same `name_prefix`), each with a `SizedQueue(1)` inbox, all created in the main thread.
- Thread body: `loop { job = inbox.pop; break if job == :stop; Rails.application.reloader.wrap { child.perform_job(job) } (bare call without Rails); record success/failure; mark idle; signal dispatcher CV }`.
- `work_off` override (called by inherited `work_loop`): repeat until stop: wait on CV until ≥1 idle thread; `Rails.application.executor.wrap { Job.reserve_batch(idle_children) }` (with the existing failed-reserve counting / `FatalBackendError` logic); push each job to its child's inbox; if none reserved → return accumulated `[success, failure]`, so `work_loop` sleeps `sleep_delay` (interruptible; also woken when a thread frees up). The per-loop `reload!` is skipped (the reloader handles it).
- `exit_on_complete`: finish only when reserve returns nothing **and** no jobs are in flight.
- Shutdown (`ensure` around the loop): push `:stop` to every inbox, join threads; running jobs finish (same graceful semantics as today). With `raise_signal_exceptions`, the trapped signal raises in the dispatcher (main) thread; `ensure` then `Thread#raise`s it into the busy threads (same mechanism as `Timeout`; documented).
- Thread crash (an exception escaping `perform_job` — rare, since `run` rescues `Exception`): the thread re-raises into the dispatcher (`Thread#raise`) → stop, join, exit non-zero → the forking parent respawns the process (existing `run_loop`).
- `ClearLocks`: the dispatcher's `:execute` callback clears its own name; add a hook so each child's name is cleared on shutdown too (iterate children in the `ensure`).
- Startup warning if `ActiveRecord::Base.connection_pool.size < thread_count + 1`.

### 4. Launchers — `lib/delayed/launcher/{base,forking,daemonized}.rb`
- `Base#initialize`: `@thread_count = options.delete(:thread_count) || 1`.
- `Base#build_worker(options)`: `n > 1 ? ThreadedWorker.new(options, n) : Worker.new(options)`; used by `run_worker` and `Forking#setup_single_worker`.
- Pools carry an optional per-pool thread count (merged into that pool's options); Forking stores it with `[worker_name, queues]` so respawns keep it; the startup log gains ` threads=N`.

### 5. CLI / rake / pools
- `Command`: `-t`, `--threads=N` → `:thread_count`; `validate_thread_count!` (≥1, ArgumentError).
- `PoolParser`: optional third field `queues:processes:threads` (e.g. `--pool=mailers:2:5`); the 2-field form is unchanged.
- `tasks.rake`: `NUM_THREADS` env (validated ≥1); `POOLS` inherits the 3-field syntax.

### 6. Test backend — `spec/delayed/backend/test.rb`
Required for JRuby: class-level Mutex; `lock_exclusively!` becomes a real compare-and-set (fail if locked by another name within `max_run_time`); guard `all`/`find_available`/`destroy`.

### 7. Docs
README (threads flag, env, pool syntax, DB pool sizing, thread-safety of job code/plugins, `reserve_batch` contract for backend authors), CHANGELOG, and the lore file `lore/<YYYYMMDD-HHMM>-multi-threaded-workers-plan.md` holding this plan (commitable).

## Rejected alternatives
- Independent worker loop per thread: simpler, but N× idle polling per process.
- Fixed-size batch fetch: jobs sit locked waiting for a thread (lock age counts against `max_run_time`).
- Per-thread queue config: blocked by class-level config read by external backends.
- In-process thread restart on crash: the process-exit + parent-respawn path already exists.

## Files
Modify: `lib/delayed/backend/base.rb`, `lib/delayed/worker.rb`, `lib/delayed/launcher/{base,forking,daemonized}.rb`, `lib/delayed/command.rb`, `lib/delayed/pool_parser.rb`, `lib/delayed/tasks.rake`, `lib/delayed_job.rb` (require), `lib/delayed/backend/shared_spec.rb` (add `reserve_batch` shared examples), `spec/delayed/backend/test.rb`, `README.md`, `CHANGELOG.md`.
Add: `lib/delayed/threaded_worker.rb`, `spec/threaded_worker_spec.rb`, lore file.

## Tests
- `shared_spec.rb`: `reserve_batch` locks distinct jobs under each worker's name, stops at the first empty reserve, and never returns a job twice.
- `worker_spec.rb`: `work_loop` installs no traps; `stop` wakes a sleeping worker promptly; thread names are unique; the single-thread path is unchanged.
- `threaded_worker_spec.rb`: 50 jobs with 4 threads + `exit_on_complete` → each run exactly once, `locked_by` spread over thread names, observed concurrency > 1 (latch job); with 2 threads and slow jobs, no job is reserved while both threads are busy; `stop` drains gracefully; an escaped exception stops the others and re-raises; `FatalBackendError` propagates.
- `command_spec`, `pool_parser_spec`, `tasks_spec`, launcher shared examples: thread-count parsing, validation, and propagation (incl. per-pool and respawn).

## Verification
1. `cd /mnt/c/workspace/delayed_job-multi-threaded && bundle exec rspec`: full suite green (test backend, no MongoDB).
2. `bundle exec rubocop` clean.
3. Smoke script: enqueue ~40 `sleep 0.5` jobs on the test backend; `Delayed::Launcher::Forking.new(worker_count: 2, thread_count: 4, exit_on_complete: true).launch` → about 8× wall-clock speedup, each job completed once; rerun and send SIGTERM mid-run → all threads/processes exit gracefully after their current jobs.

## Implementation notes (as built)
- `:thread_count` travels inside each process's options hash (not a launcher ivar), so pools override it per pool and Forking respawns keep it (`workers[pid] = [name, options]`).
- `ThreadedWorker.lifecycle`/`setup_lifecycle` delegate to `Worker`: the lifecycle is a class-level ivar, so a subclass would otherwise get its own empty one and plugins (ClearLocks) would never fire.
- Child threads each run the `:execute` callbacks, so ClearLocks releases every thread's locks on exit; the dispatcher runs `:loop`.
- `reserve_batch` returns already-locked jobs if a later reserve in the batch raises, so they are not stranded until `max_run_time`.
- Pre-existing breakages fixed on the way (needed to run specs on Ruby 4 / ActiveSupport 7.2): unused `require 'ostruct'` in the test backend; missing `active_support/core_ext/kernel/reporting` require for `silence_warnings` in worker.rb.
- Two pre-existing spec failures remain, unrelated (Ruby 3.4+ backtrace quote style; `US/Eastern` tz missing from tzdata).
- rubocop 0.48 (pinned) cannot run on Ruby 4 (Psych API); lint is verified by CI only.
- Smoke (2 procs × 4 threads, sqlite, 40 × 0.5s jobs): 2.6s vs 20s serial, max concurrency 8, 0 duplicates; SIGTERM mid-run drained in-flight jobs, left no locks, all exit 0.

## Follow-up: Poller refactor (replaces ThreadedWorker)
`ThreadedWorker < Worker` was the wrong abstraction: it never ran jobs, had to override `lifecycle`/`setup_lifecycle`/`reload!` to undo inherited behaviour, and fired `:execute` N+1 times. Replaced with:
- `Delayed::Poller` (`lib/delayed/poller.rb`): the one golden path for every worker process, single- or multi-threaded. Owns signal traps, poll loop, `exit_on_complete`, throughput logging, threads, shutdown, crash propagation. Even thread_count=1 runs the job on a worker thread.
- `Delayed::Worker`: only runs jobs (`perform_job`, `run`, reschedule/fail). `Worker#start` = `Poller.new(:workers => [self]).start`; `Worker#stop` also stops its poller. `Worker#work_off` kept as the inline (no-thread) path for tests/console/`Job.work_off` — a legitimately separate role, not a duplicate loop.
- Shared pieces extracted instead of duplicated: `Delayed::Logging#say`, `Delayed::ReservationGuard#guard_reservation` (10-failure FatalBackendError logic), `Worker.default_name`.
- `:loop` callback (cleanest, not most compatible): yields the Poller and wraps each poll. Breaking for plugins expecting a Worker; documented in CHANGELOG. `Lifecycle::EVENTS[:loop]` arg renamed `:poller`.
- Removed `Worker.reload_app?`/`#reload!`: the Rails reloader wraps each job instead.
- Launchers construct `Delayed::Poller.new(options)` directly (no `build_worker` branching).
- Verified: full suite (same 2 pre-existing env failures), poller/worker/launcher specs 10/10, smoke 2×4 threads (2.6s, concurrency 8, 0 dupes; SIGTERM drains cleanly) and 2×1 thread (10.1s, concurrency 2).

## Follow-up: reservation in one place
`Delayed::ReservationGuard` removed. All job reservation (and the 10-consecutive-failures → `FatalBackendError` guard) now lives in `Poller#reserve`. `Worker#work_off` delegates to `Poller#work_off(num, worker)` (inline, calling thread, no `:loop` callbacks), reusing the worker's poller so the failure count persists across calls. `Worker#reserve_job`/`#reserve_and_run_one_job` removed. Also fixed: `Worker#run` returned `failed(job)`'s value on `DeserializationError` (usually nil), which the old `work_off` treated as "queue empty" and stopped; it now returns false.

## Follow-up: processes naming; no per-pool threads
- Per-pool thread counts (`queues:processes:threads`) removed: `--threads`/`NUM_THREADS` applies to every process, including pool processes. `PoolParser` is back to `[queues, process_count]`; a third field is ignored, as before.
- Process count renamed: CLI `-n`/`--processes=N` (`--num-workers` and `--number_of_workers` deprecated, both warn pointing to `--processes`), rake `NUM_PROCESSES` (`NUM_WORKERS` alias; `NUM_PROCESSES` wins if both are set), launcher/options keys `:processes` and `:threads` (`:worker_count` accepted by `Launcher::Base`; `#worker_count` aliases `#processes`; the never-released `:process_count`/`:thread_count` keys have no alias). Validation messages say `--processes`/`NUM_PROCESSES`.

## Follow-up: Poller renamed to Dispatcher
`Delayed::Poller` → `Delayed::Dispatcher` (`lib/delayed/dispatcher.rb`, `spec/dispatcher_spec.rb`); `Worker#poller` → `#dispatcher`; `:loop` callback argument `:poller` → `:dispatcher`. Polling is the smallest part of the class; its defining job is reserving work only for idle threads and handing it to them, plus owning the process's threads/signals/shutdown. Renamed before release, so no alias. Earlier sections of this file use the old name.
