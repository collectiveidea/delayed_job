# Plan: Mold process for the forking launcher (port of Puma's `mold_worker`) [experimental]

**Naming:** "mold process". In delayed_job, "worker" means a `Delayed::Worker` thread, and the CLI already counts `--processes`. Setting: `Delayed::Worker.mold`; CLI: `--mold[=JOBS,...]`; rake: `MOLD=`; class: `Delayed::Launcher::Mold`. Docs, logs and events say "child process" for the forked processes, matching the launcher's existing logs, and "mold" for the template. Below, "worker" in Puma's context means a Puma worker; in delayed_job's, it means a child process.

**Branch:** a new `mold` branch off `multi-threaded` in `/mnt/c/workspace/delayed_job-multi-threaded`, raised with `gh pr create --base multi-threaded`.

## Context
Puma 8 added `mold_worker` (`/mnt/c/workspace/puma`, `docs/fork_worker.md`; commits 628cae7c, 19bb5748 and a57f8d93).
- When a worker reaches a request threshold, Puma promotes it to a **mold**: a process that stops serving and only forks new workers.
- Every worker is then reforked from the mold, so they share its *warmed* memory copy-on-write: lazily loaded constants, YJIT code, memoized caches and a compacted heap.

delayed_job's forking launcher forks every child from the parent. The parent is eager-loaded and warmed (`Launcher::Base#prepare_for_fork`) but has never run a job. Job workers live for days and each one warms up separately, so their memory drifts apart. Reforking from a warm mold should bring it back together.

Ship this as **experimental** and measure the gain (step 4 of Verification) before recommending it.

Target: `/mnt/c/workspace/delayed_job-multi-threaded`, branch `mold` (off `multi-threaded`). delayed_job_mongoid needs no change: the mold uses the existing `backend.before_fork` / `after_fork`.

### Puma's design (what we port)
- **Trigger:** a worker ping shows `requests_count` ≥ the current threshold (`mold_worker 1000, 2000, 4000`), every worker is in the current phase, and no restart is pending. SIGURG to the master promotes at any time.
  - Thresholds count per worker from its boot.
  - The threshold index advances once per promotion.
- **Promote:** the master takes the booted worker with the most requests out of `@workers` and sends it SIGURG. The worker stops serving, runs `after_mold_promotion`, then writes `m` to the master over the shared status pipe.
- **Activate:** on `m`, the master retires the old mold (SIGURG means stop forking) and starts a refork phase.
  - Each replacement is requested by writing a fixed-size index (`pack("L")`, atomic) to a fork pipe shared by all descendants.
  - Only the active mold reads that pipe. It forks, then replies `f pid:idx`.
- **Retired molds** stay alive until their workers are gone, since they are those workers' parent and reap them. The master then terminates them.
- **Mold death:** the master drains the fork pipe and forks from itself again. On Linux, a C-extension `prctl(PR_SET_CHILD_SUBREAPER)` reparents orphaned workers to the master.

## Key decisions (where delayed_job differs)
1. **Opt-in, and without it the launcher stays exactly as it is.** The pipes, the ping thread, the URG traps and the polling branch exist only when `mold` is set. The `Process.wait2` run loop is not rewritten.
2. **Threshold = jobs performed per child process since boot** (succeeded + failed). Set it with `Delayed::Worker.mold = [1000, 2000, 4000]`: `true` means `[1000]`, `nil` (the default) means off. After the last threshold, only SIGURG to the parent promotes.
3. **Promotion is a graceful stop that ends in mold mode instead of exit.** SIGURG to the child calls `Dispatcher#promote`, which is `stop` plus a flag.
   - The existing `stop_threads` path then runs unchanged: prefetch-queued jobs are released, running jobs finish (interrupted and released after `shutdown_timeout` if it's set), and slot locks are cleared.
   - Then `Launcher::Base#run_worker` calls `Mold#run` instead of returning.
   - **Candidate:** the worker with the most jobs performed, preferring one with no busy threads (the ping reports the busy count). This keeps the promotion wait short when jobs are long.
4. **Refork forks the replacement before stopping the old worker** (Puma does it the other way round). Job workers pull work and hold no socket, so capacity never drops.
   - The old worker is marked `retiring`, so its exit is not replaced.
   - Reforks go one at a time: the next step waits until the previous replacement has booted *and* the previous old worker has exited. That caps the cluster at N+1 processes, plus the mold, and the DB connections with it.
   - The promoted worker's slot is refilled first.
5. **Exit statuses come through the mold, not a subreaper.** A mold-forked worker isn't the launcher's child, so the launcher can't `wait` on it.
   - The mold reaps it and reports `x <pid> <exitstatus> <termsig>`.
   - The launcher wraps that in a `Delayed::ReportedStatus` (`success?`, `signaled?`, `termsig`, `exitstatus`, `to_s`) and passes it to the existing `handle_exit`. Recovery, respawn back-off and `process_exited` are reused as-is.
   - Recovery is name-based (`lock_names` include the pid, known from `f`), so being the parent isn't needed.
   - There's no `prctl`: plain Ruby has no binding for it, and Fiddle is a bundled gem since Ruby 3.5.
6. **When a mold dies:**
   - its workers notice that `Process.ppid != supervisor_pid` (the existing `supervisor_gone?`) and stop gracefully, releasing their jobs;
   - the launcher drains unread fork requests and forks them itself;
   - it polls the orphaned pids with `Process.kill(0)`, and once each one is gone it recovers that worker's still-locked jobs and replaces it from the parent;
   - if the launcher dies, the mold exits, and its workers then stop the same way.
7. **Pipes**, created by the parent before its first fork:
   - **Fork pipe:** fixed 8-byte records `pack("NN")` holding `worker_index` and `pool_index`. The mold rebuilds the name and options from its inherited `pools` / `@options`, so nothing is marshalled.
   - **Status pipe:** single lines under `PIPE_BUF`, so writes are atomic:
     - `b` booted;
     - `p <pid> <jobs> <busy>` ping, every `MOLD_PING_INTERVAL = 5`s, sent with `write_nonblock` and dropped if the pipe is full, so a slow launcher never blocks a worker;
     - `m` mold ready;
     - `f <pid> <worker_index>` forked;
     - `x <pid> <exitstatus> <termsig>` exited.
     
     `m`, `f` and `x` use blocking writes, because they must arrive.
   - A retired mold never reads the fork pipe again.
8. **Scope:** forking mode only, on platforms with fork.
   - `mold` makes `forking?` true even with `-n 1`. With one process there's no capacity while the only worker is promoted, which the docs will say.
   - ArgumentError with `--identifier`, with the daemonized launcher, or without `fork` (JRuby, TruffleRuby).
   - There's no phased restart, since delayed_job has no code reload.
9. **Hooks use delayed_job's own idiom:** a new lifecycle event `:mold => [:pid]` runs around the mold's fork loop.
   - `lifecycle.before(:mold)` stands in for Puma's `after_mold_promotion` (e.g. close clients).
   - `lifecycle.after(:mold)` stands in for `before_mold_shutdown`.
   - Before its first fork, the mold always runs `warmup_heap` (GC and compact, with the dead job threads' garbage gone) and `Delayed::Worker.before_fork`.

## Changes

### 1. Settings — `lib/delayed/worker.rb`
- `cattr_accessor :mold`, reset in `Worker.reset`.
- `mold_thresholds` normalises the setting.
- `validate_mold!` requires positive integers and is called from `validate_settings!`.

### 2. Dispatcher — `lib/delayed/dispatcher.rb`
- `#promote` (signal-trap safe) and `#promoted?`. Jobs released by promotion report `jobs_released reason: 'promotion'`.
- A cumulative `#jobs_performed` counter, bumped in `job_finished`. Stats `report` resets its own counters; this one is never reset.
- The `URG` trap is installed only when the `:mold` option is passed (with `check_trappable!`, like QUIT).

### 3. Child side — `lib/delayed/launcher/base.rb` and new `lib/delayed/launcher/mold.rb`
- **`run_worker`** (mold mode only):
  - writes `b`, then starts the ping thread;
  - passes `:mold` to the dispatcher;
  - once `dispatcher.start` returns with `promoted?` set, stops the ping thread and runs `Mold.new(launcher, pipes).run`.
- **`Delayed::Launcher::Mold`:**
  - sets its procline (`delayed_job.3: mold gen 2`), runs `before_fork` and `warmup_heap`, runs the `:mold` lifecycle around `fork_loop`, writes `m` once ready, then `exit!(0)`s after the hooks;
  - `fork_loop` waits on `IO.select([fork_pipe, self_pipe])`, and its traps only write to the self-pipe:
    - **on a fork record:** fork, close the self-pipe in the child, and call `run_worker(name, options)` with `supervisor_pid: Process.pid`; then write `f`;
    - **on CHLD:** reap with `WNOHANG`, writing an `x` per child;
    - **on URG (retired):** stop reading the fork pipe;
    - **on TERM, INT or QUIT:** stop forking; the launcher signals the workers itself;
  - it exits once it is retired or stopping and has no children left;
  - every select times out after 1s to check `Process.ppid`, so it exits as soon as the launcher is gone.

### 4. Parent side — `lib/delayed/launcher/forking.rb`
- **Records:** `workers` values become a `Child` Struct with fields `name`, `options`, `pool_index`, `mold_pid`, `jobs`, `busy`, `booted`, `retiring`. `forward_signal`, `signal_workers`, `kill` and `handle_exit` read it.
  - Molds go in `@molds`, with roles `:promoted`, `:active` or `:retired`, and are signalled and awaited on shutdown like workers.
- **`wait_for_child`:** in mold mode only, it uses the polling branch that already exists for pending replacements. Each pass:
  - reaps with `WNOHANG`;
  - waits up to 0.1s on `IO.select([status_read])` and handles the lines;
  - polls orphans;
  - runs `advance_refork` and `replace_due_workers`.
  
  Without `mold` it keeps the blocking `Process.wait2`.
- **`add_worker`:**
  - with an active mold, it writes a fork record and records a pending child keyed by `worker_index`; the pid, the `process_spawned` event and `catch_up_on_stop` follow on `f`;
  - otherwise it forks directly, as it does now.
- **Promotion:**
  - `maybe_promote` runs on `p` lines under Puma's conditions. A parent SIGURG trap only sets a flag, which the loop picks up.
  - `promote_mold` picks the candidate (decision 3), moves it to `@molds` as `:promoted`, and sends it URG. A slot that's empty while the candidate drains is refilled from the new mold first.
  - **`activate_mold`, on `m`:** retires the old active mold (URG), sets the new one active, bumps `@generation`, and starts the refork.
  - **`advance_refork`:** works through old-generation workers, one at a time (decision 4).
  - **Once the refork completes:** sends TERM to retired molds that have no live workers left.
- **Mold exit:**
  - drains the fork pipe and re-forks pending requests from the parent;
  - moves its still-live workers to `@orphans` (decision 6);
  - a promoted mold that dies before `m` just frees its slot for a normal replacement.
- **`reap_killed_workers`:** for pids that aren't its own children, it waits with `kill(0)` instead of `waitpid2`. Today `waitpid2` raises ECHILD there and recovery is skipped.

### 5. CLI, rake, events and docs
- **CLI and rake:**
  - `Command`: `--mold[=JOBS,...]` (an OptionParser Array; bare `--mold` means 1000);
  - `tasks.rake`: `MOLD=1000,2000,4000` (`MOLD=true` means the default 1000).
- **New events** in the `<subject>_<what happened>` style, documented in the `docs/monitoring.md` table:
  - `mold_promoted`: worker, pid, jobs, trigger `:threshold` or `:signal`;
  - `mold_activated`: pid, generation;
  - `mold_retired`: pid.
  
  `process_spawned` also gains `:mold_pid`.
- **README:** a "Mold process (experimental)" section covering:
  - what it does and when it helps;
  - thresholds and SIGURG;
  - the `:mold` hook;
  - two caveats: promotion waits for the candidate's running jobs (bounded by `shutdown_timeout`), and a mold's workers stop if it dies;
  - it needs fork.
- **Other docs:**
  - `docs/deployment.md`: one line, plus how to measure the gain with PSS (`/proc/<pid>/smaps_rollup`);
  - a CHANGELOG entry;
  - the lore file `lore/<YYYYMMDD-HHMM>-mold-process-plan.md`, holding this plan.

## Tests
- **Unit tests** (`spec/mold_spec.rb`):
  - setting normalisation and validation;
  - `Dispatcher#promote` releases queued jobs, lets running ones finish, sets `promoted?`, and publishes `jobs_released reason: 'promotion'`;
  - `jobs_performed` is cumulative;
  - `ReportedStatus` behaves like `Process::Status` in `ProcessExitError` and the exit logs;
  - fork records and status lines round-trip.
- **Process tests** (`spec/processes/mold_spec.rb`, a real launcher via `ProcessHelpers`, skipped without fork):
  - 2 processes with a threshold of 5 promote a mold, and the workers' ppid becomes the mold's pid;
  - every job runs exactly once across the refork, and none is left locked;
  - SIGURG to the parent promotes again, and the old mold exits once its workers are replaced;
  - SIGKILL to a mold-forked worker: an `x` is reported, its jobs are recovered (attempt counted), and it's replaced from the mold;
  - SIGKILL to the mold: its workers stop by themselves, their jobs are released or recovered, and they're replaced from the parent;
  - TERM to the parent mid-refork: everything, molds included, exits gracefully, and no job is left locked;
  - pools keep their queues across a refork;
  - `-n 1` works.
- **Guards:** ArgumentError with `--identifier`, with the daemonized launcher, and without fork.
- **Regression:** the existing suite passes unchanged (`spec/processes/*`, `supervisor_spec`). The non-mold launcher path is untouched.

## Verification
1. `cd /mnt/c/workspace/delayed_job-multi-threaded && timeout -s KILL 900 bundle exec rspec` passes on CRuby. On JRuby, the mold specs are skipped and the rest stays green.
2. `bundle exec rubocop` is clean.
3. The delayed_job_mongoid suite passes against the branch (`DELAYED_JOB_PATH=…`), using local MongoDB.
4. Smoke test on Mongoid: 4 processes × 2 threads, `--mold=50`, 1,000 small jobs.
   - `ps -o pid,ppid,rss,cmd` shows the workers reparented under the mold.
   - Total PSS (`smaps_rollup`) before and after the refork records the gain.
   - SIGTERM mid-refork leaves no job locked.
5. **Delivery:**
   - `git checkout -b mold multi-threaded`;
   - commit the lore file with the plan's major items in the message, then commit the implementation;
   - push and run `gh pr create --base multi-threaded`, with Why = memory (copy-on-write sharing of warmed workers), ending with the Claude Code attribution line.

---

## Update (2026-11-15): architecture after review

Five reviews were run: parent-side hardening, child/mold-side hardening, a comparison with Puma, a dig through Puma's history, and a study of Shopify's Pitchfork. They superseded parts of the plan above. The code now works as follows.

### Classes
- **`Forking`** is one class. In mold mode it calls the supervisor through explicit `@mold_supervisor&.` hooks. It also holds the child side of promotion: the URG trap, the ping thread, `promote_to_mold`, `fork_mold` and `run_mold`.
- **`MoldSupervisor`** is the parent-side state machine, created only with `Worker.mold`.
- **`Mold`** is the mold process, and **`Mold::Pipes`** is the protocol:
  - fork records are 12 bytes (`NNN`: worker index, pool index, generation);
  - status lines are `b`, `p` (with a fork-unsafe flag), `M`, `m` (with the promoted child's pid), `f`, `e` (fork failed) and `x` (with the mold's pid).
- **`ProcessUtil`** provides the subreaper (Fiddle `prctl`), a zombie-aware `alive?` and `pss_kb`.

### Decisions
- **Subreaper (Linux, `fiddle` gemspec dependency).** Molds, and the children of a dead mold, reparent to the parent, which `wait`s on them. A child accepts either its mold or the launcher as its parent (`supervisor_pid` is an array). Without a subreaper, it falls back to `kill(0)` polling, where zombies and EPERM count as gone, and children stop when their mold dies.
- **No double fork.** The subreaper gives nearly all of its benefit. Puma promotes in place; ours forks the mold and exits, and with the subreaper every mold is a direct child of the parent.
- **Retired molds exit at once** when the parent adopts their children; otherwise they exit once their children have.
- **A lost mold** (died, broken after 3 boot failures in a row, or hung on a fork) means the parent forks pending children itself, then promotes a new mold (`trigger: :mold_lost`). The back-off doubles per failure in a row and resets after 10 minutes of a stable mold.
- **Refork** runs about 10% of the children at a time, idle ones first. Each step is tied to its replacement: the old child is stopped once the replacement boots, and if the replacement dies first, the old child is kept.
- **Promotion:**
  - The mold is forked only after a clean stop (no job or heartbeat thread left alive) and with no signal pending; otherwise the child exits with status 75 and the promotion is retried.
  - The threshold advances only once the mold is active.
  - The slot of a promoted child that is still draining is refilled after 5 minutes.
- **Timeouts:**
  - boot: 60s;
  - mold fork: 30s, then KILL;
  - mold ready: 120s;
  - mold forked: 5s after the promoted child exits.
- **Skipped:**
  - unlimited reforking at the last threshold;
  - a stop-first refork mode;
  - molds sending pings;
  - per-fork hooks in the mold;
  - Pitchfork-only mechanisms;
  - phased restart.
