require 'set'

module Delayed
  # Runs a worker process's Delayed::Workers, one per thread, and feeds them
  # jobs. Each poll reserves at most one job per free slot (Job.reserve_batch),
  # so the database is polled once per cycle and no job stays locked waiting
  # for a thread. With Worker.prefetch N, each worker also holds up to N queued
  # jobs, each locked under a slot name (Worker.slot_name); they are released
  # unstarted on shutdown.
  #
  # Callbacks: :loop wraps each poll (yields the Dispatcher); :execute wraps
  # each worker thread (yields the Worker, so ClearLocks runs per worker);
  # :perform, :error and :failure yield the Worker running the job.
  #
  # Queue and priority settings are process-wide (Worker class settings).
  class Dispatcher # rubocop:disable Metrics/ClassLength
    include Logging

    # Raised into worker threads to interrupt their jobs on shutdown.
    SHUTDOWN_INTERRUPTS = [ShutdownInterrupt, SignalException].freeze

    # Per-run stop flag for the heartbeat thread.
    HeartbeatControl = Struct.new(:mutex, :cond, :stopped)
    DEFER_SHUTDOWN_INTERRUPTS = SHUTDOWN_INTERRUPTS.to_h { |klass| [klass, :never] }.freeze
    ALLOW_SHUTDOWN_INTERRUPTS = SHUTDOWN_INTERRUPTS.to_h { |klass| [klass, :immediate] }.freeze

    # Consecutive reservation failures before raising FatalBackendError.
    MAX_FAILED_RESERVATIONS = 10

    # Consecutive non-StandardError heartbeat failures before it gives up.
    MAX_HEARTBEAT_CRASHES = 5

    # Seconds to wait for the heartbeat thread on stop before abandoning it.
    HEARTBEAT_STOP_TIMEOUT = 5

    # Log throughput at least every this many jobs while busy.
    REPORT_EVERY = 100

    # Seconds to wait for interrupted jobs to stop before giving up on them.
    INTERRUPT_GRACE = 5

    # Seconds between parent-alive checks, even while all threads are busy.
    SUPERVISOR_CHECK_INTERVAL = 1

    # Lets shutdown interrupts in for the block (used around a job's #perform);
    # worker threads defer them everywhere else (see #work).
    def self.interruptible(&block)
      return yield unless interrupt_masking?
      Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS, &block)
    end

    def self.worker_thread?
      !!Thread.current[:delayed_job_worker_thread]
    end

    # Defers shutdown interrupts for the block (see #work).
    def self.deferring_interrupts(&block)
      return yield unless interrupt_masking?
      Thread.handle_interrupt(DEFER_SHUTDOWN_INTERRUPTS, &block)
    end

    # Without these, shutdown interrupts are never deferred.
    def self.interrupt_masking?
      Thread.respond_to?(:handle_interrupt) && Thread.respond_to?(:pending_interrupt?)
    end

    # TruffleRuby's Thread.pending_interrupt? takes no class: any pending
    # interrupt counts then (#discard_stale_interrupts only lets in shutdown
    # ones).
    def self.pending_interrupt_by_class?
      return @pending_interrupt_by_class if defined?(@pending_interrupt_by_class)
      @pending_interrupt_by_class = Thread.method(:pending_interrupt?).arity != 0
    end

    attr_reader :workers, :name_prefix

    # Parent (launcher) pid. If it goes away (e.g. SIGKILL), the dispatcher
    # stops instead of running on as an orphan.
    attr_accessor :supervisor_pid

    # Options are Delayed::Worker's, plus:
    # * :threads - number of worker threads (default 1)
    # * :workers - use these workers instead of building new ones
    # * :supervisor_pid - see #supervisor_pid
    # * :procline - process name; while running, $0 is kept as e.g.
    #   "delayed_job.0: 3/4 busy, queues=*" (see #procline)
    def initialize(options = {})
      @quiet = options.key?(:quiet) ? options[:quiet] : true
      @workers = options[:workers] || build_workers(options)
      raise ArgumentError, 'threads must be 1 or greater' if @workers.empty?
      @workers.each { |worker| worker.dispatcher = self }
      @supervisor_pid = options[:supervisor_pid]
      @procline_name = options[:procline]
      @stopped = false
      @quit = false
      @promoted = false
      @stop_requested_at = nil

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @inboxes = {}
      @slots = {} # worker => slots (Workers) it locks its jobs under
      @slot_owner = {} # slot => worker
      @slot_jobs = {} # slot => job it holds (queued or running)
      @slot_refreshed = {} # slot => last heartbeat refresh (monotonic)
      @running_slot = {} # worker => slot of the job it is running
      @dead = [] # workers whose thread crashed
      @prefetch = 0
      # Queue depth (see #adjust_depth); written only by the dispatcher thread.
      @depth = 0
      @threads = []
      @running = {} # thread => job it is running
      # worker => [job, started_at, limit, label, overrun_reported]
      @jobs_started = {}
      @events = 0
      @thread_error = nil
      @failed_reserve_count = 0
      @performed = 0 # Never reset, unlike the stats.
      reset_stats
    end

    def thread_count
      workers.size
    end

    def name
      Worker.default_name(name_prefix)
    end

    def name_prefix=(prefix)
      @name_prefix = prefix
      workers.each { |worker| worker.name_prefix = prefix }
    end

    # Installs signal traps, handles signals received before that (see
    # Launcher::Forking#fork_worker), then runs.
    def start(pending_signals = [])
      trap_signals
      pending_signals.each { |signal| handle_pending_signal(signal) }
      run
    end

    # Runs until stopped (or out of jobs with Worker.exit_on_complete), letting
    # running jobs finish. Installs no signal traps.
    def run
      say thread_count > 1 ? "Starting job worker with #{thread_count} threads" : 'Starting job worker'
      warn_if_connection_pool_too_small
      Delayed.instrument(:process_started, process_payload)
      error = nil
      begin
        with_lock_heartbeat do
          start_threads
          poll_loop
        rescue Exception => error # rubocop:disable Lint/RescueException
          # Worker thread crashes were reported by the thread.
          thread_error(error, 'Dispatcher') unless stopping_error?(error)
          raise
        ensure
          stop_threads(error)
        end
      ensure
        Delayed.instrument(:process_stopped, process_payload.merge(:error => error || @thread_error))
      end
    end

    # Runs up to `num` jobs inline with `worker`; returns [succeeded, failed].
    def work_off(num = 100, worker = workers.first)
      success = 0
      failure = 0
      with_lock_heartbeat do
        num.times do
          _, job = reserve([worker]).first
          break unless job
          untrack_job_after(worker) { worker.perform_job(job) } ? success += 1 : failure += 1
          break if worker.stop?
        end
      end
      [success, failure]
    end

    # Stops polling; running jobs finish (interrupted after
    # Worker.shutdown_timeout, see #quit). Signal-trap safe.
    def stop
      @stop_requested_at ||= monotonic_now
      @stopped = true
      wake_up
    end

    def stop?
      @stopped
    end

    # Interrupts running jobs with ShutdownInterrupt and releases them,
    # attempts unchanged. Signal-trap safe.
    def quit
      @quit = true
      stop
    end

    def quit?
      @quit
    end

    # Stops like #stop, then the launcher turns this process into a mold (see
    # Launcher::Mold). No-op once stopping. Signal-trap safe.
    def promote
      return if stop?
      @promotion_started = true
      @promoted = true
      stop
    end

    def promoted?
      @promoted
    end

    # A signal (or the parent going away) overrides a promotion: the process
    # then exits instead (see #promotion_cancelled?). Returns whether it was
    # promoted. Signal-trap safe.
    def cancel_promotion
      promoted = @promoted
      @promoted = false
      promoted
    end

    # Promoted, then stopped by a signal (or its parent going away) instead.
    def promotion_cancelled?
      !!@promotion_started && !@promoted
    end

    # Jobs performed (succeeded or failed) since start.
    def jobs_performed
      synchronize { @performed }
    end

    def busy_threads
      synchronize { busy_count }
    end

    # No job or heartbeat thread is left running (once stopped): safe to
    # fork, as nothing is frozen mid-way in the child.
    def cleanly_stopped?
      @threads.none?(&:alive?) && !(@heartbeat && @heartbeat.alive?)
    end

    # Process title, e.g. "delayed_job.0: 3/4 busy, queues=mail,sms".
    def procline
      state = if quit? then 'quitting, '
      elsif promoted? then 'promoting, '
      elsif stop? then 'stopping, '
      end
      busy, held = synchronize { [busy_count, @slot_jobs.size] }
      "#{@procline_name}: #{state}#{busy}/#{thread_count} busy#{prefetch_state(held - busy)}, queues=#{queue_names}"
    end

    # Procline suffix: queued jobs, and the depth if dynamic.
    def prefetch_state(queued)
      return '' unless @prefetch > 0
      depth = ", depth #{@depth}/#{@prefetch}" if Worker.prefetch_dynamic
      ", #{queued} queued#{depth}"
    end

    # Called by Worker#run as the job starts, for the heartbeat (see
    # #heartbeat_names). The label is built here, on the job's thread inside
    # its :perform callbacks, so the heartbeat thread never calls into the job.
    def job_timed(worker, job, limit)
      limit = nil unless limit > 0 # No timeout under a second.
      label = limit && job_label(job)
      synchronize { @jobs_started[worker] = [job, monotonic_now, limit, label] }
    end

  private

    def build_workers(options)
      count = Integer(options[:threads] || 1)
      Array.new([count, 0].max) do |index|
        # Worker.new resets the global lifecycle: build all before threads start.
        Worker.new(options).tap { |worker| worker.thread_index = index if count > 1 }
      end
    end

    # INT/TERM stop gracefully, raising SignalException per
    # Worker.raise_signal_exceptions. QUIT: see #quit.
    def trap_signals
      trap('TERM') do
        first = cancel_promotion || !stop? # A promotion's stop wasn't the signal's.
        Thread.new { say 'Exiting...' } if first
        stop
        raise_signal('TERM') if first && Worker.raise_signal_exceptions
      end

      trap('INT') do
        first = cancel_promotion || !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise_signal('INT') if first && Worker.raise_signal_exceptions && Worker.raise_signal_exceptions != :term
      end

      trap_quit
    end

    # Raise in the main thread: CRuby runs traps there, JRuby on its own thread.
    def raise_signal(signal)
      raise SignalException, signal if Thread.current == Thread.main
      Thread.main.raise(SignalException, signal)
    end

    # The JVM (JRuby) reserves QUIT for thread dumps; TERM and INT still work.
    def trap_quit
      return unless Signal.list.key?('QUIT')
      Delayed.check_trappable!('QUIT')
      trap('QUIT') do
        Thread.new { say 'Received SIGQUIT: interrupting running jobs and exiting...' }
        cancel_promotion
        quit
      end
    rescue ArgumentError => error
      say "WARNING: cannot trap SIGQUIT on this platform (#{error.message}); use TERM or INT to stop", 'warn'
    end

    # Like the trap, but raises no SignalException: nothing is running yet.
    def handle_pending_signal(signal)
      say "Received SIG#{signal} while starting", 'warn'
      cancel_promotion
      signal == 'QUIT' ? quit : stop
    end

    def poll_loop
      until stop?
        update_procline
        raise_thread_error
        break if supervisor_gone?
        free, seen = snapshot
        polled_at = monotonic_now # No later than the jobs' locks were taken.
        reserved = free.empty? ? [] : poll(free)
        # A crashed thread's job is unlocked only after its crash is recorded:
        # a poll that reserved it stops here instead of handing it to another
        # thread. Undispatched jobs (also after a signal exception) stay
        # locked until their worker's names are cleared on thread exit
        # (ClearLocks, #clear_slot_locks); those reserved for a thread that
        # already exited (its locks cleared) are released here.
        release_reserved(reserved) if @thread_error
        raise_thread_error
        reserved.each { |slot, job| dispatch(slot, job, polled_at) }
        deeper = adjust_depth(free.size, reserved.size)

        if reserved.empty? && in_flight.zero?
          report
          # A job finishing during the poll may have enqueued another: poll
          # again before concluding none is left.
          if Worker.exit_on_complete && !finished_since?(seen)
            say 'No more jobs available. Exiting'
            break
          end
        elsif completed >= REPORT_EVERY
          report
        end

        update_procline
        # Poll again at once if the depth grew (slots to fill), or after a
        # partial batch that may have lost candidates to other processes.
        next if deeper || repoll_after?(reserved, free)

        # Queue ran dry: idle workers wait at most sleep_delay, not for a busy one.
        wait_before_next_poll(seen, !free.empty? && reserved.size < free.size)
      end
      raise_thread_error
    end

    # After a partial batch, if the backend says jobs may be left.
    def repoll_after?(reserved, free)
      return false if reserved.empty? || reserved.size >= free.size
      Delayed::Job.respond_to?(:partial_batch_may_leave_jobs?) && Delayed::Job.partial_batch_may_leave_jobs?
    end

    # Waits for a worker to free up, a stop, or (queue dry) sleep_delay.
    # A supervised dispatcher also checks its parent every
    # SUPERVISOR_CHECK_INTERVAL, without polling the database.
    def wait_before_next_poll(seen, queue_dry)
      deadline = monotonic_now + sleep_delay if queue_dry
      loop do
        remaining = deadline && deadline - monotonic_now
        return if remaining && remaining <= 0
        timeout = [remaining, (SUPERVISOR_CHECK_INTERVAL if supervisor_pid)].compact.min
        return if wait_for_event(seen, timeout)
        return if supervisor_gone?
      end
    end

    def sleep_delay
      Worker.sleep_delay || Worker::DEFAULT_SLEEP_DELAY
    end

    # Re-parented (parent died): stops gracefully.
    def supervisor_gone?
      return false unless supervisor_pid && !ProcessUtil.parent_alive?(supervisor_pid)
      say "Parent process #{Array(supervisor_pid).first} is gone; stopping", 'warn'
      cancel_promotion
      stop
      true
    end

    def poll(free)
      reserved = []
      Worker.lifecycle.run_callbacks(:loop, self) { reserved = reserve(free) }
      reserved
    end

    # With Worker.prefetch_dynamic: one level deeper (up to Worker.prefetch)
    # after a full batch, back to 0 after a partial one. Returns whether it grew.
    def adjust_depth(requested, reserved)
      return false unless Worker.prefetch_dynamic && requested > 0
      synchronize do
        previous = @depth
        @depth = reserved < requested ? 0 : [@depth + 1, @prefetch].min
        @depth > previous
      end
    end

    # Reserves up to one job per worker. On error, lets the backend recover
    # and returns no jobs.
    def reserve(workers)
      reserved = Delayed.instrument(:jobs_reserved, :dispatcher => name, :requested => workers.size, :depth => @depth) do |payload|
        payload[:reserved] = 0
        polling { Delayed::Job.reserve_batch(workers, Worker.lock_expiry) }.tap { |r| payload[:reserved] = r.size }
      end
      @failed_reserve_count = 0
      reserved
    rescue SignalException, SystemExit
      # Stopping, not a failed reservation.
      raise
    rescue ::Exception => error # rubocop:disable Lint/RescueException
      say "Error while reserving job: #{error}"
      thread_error(error, 'Reservation')
      Delayed::Job.recover_from(error)
      @failed_reserve_count += 1
      raise FatalBackendError if @failed_reserve_count >= MAX_FAILED_RESERVATIONS
      []
    end

    def with_lock_heartbeat
      return yield unless start_lock_heartbeat
      begin
        yield
      ensure
        stop_lock_heartbeat
      end
    end

    def start_lock_heartbeat
      return false if Worker.lock_heartbeat_interval.nil?
      Worker.validate_lock_heartbeats!
      unless Delayed::Job.lock_heartbeats?
        say "WARNING: lock heartbeats are enabled, but #{Delayed::Job.name} does not support them; " \
            'locks expire after max_run_time', 'warn'
        return false
      end
      @last_beat_at = monotonic_now
      # Per run, so a heartbeat left behind (see #stop_lock_heartbeat) can't revive.
      control = @heartbeat_control = HeartbeatControl.new(Mutex.new, ConditionVariable.new, false)
      @heartbeat = spawn_thread('delayed_job heartbeat') { lock_heartbeat_loop(Worker.lock_heartbeat_interval, control) }
      true
    end

    # A heartbeat stuck in a refresh is abandoned after HEARTBEAT_STOP_TIMEOUT
    # so the process can exit; it stops at its next beat if it returns.
    def stop_lock_heartbeat
      control = @heartbeat_control
      control.mutex.synchronize do
        control.stopped = true
        control.cond.broadcast
      end
      return if @heartbeat.join(HEARTBEAT_STOP_TIMEOUT)
      say "Lock heartbeat did not stop within #{HEARTBEAT_STOP_TIMEOUT}s (a lock refresh may be stuck); " \
          'not waiting for it', 'warn'
    end

    # Non-StandardErrors (e.g. NoMemoryError) are reported and retried next
    # interval to keep running jobs' locks alive, up to MAX_HEARTBEAT_CRASHES
    # in a row; then locks expire after lock_timeout. Signals/exits end it.
    def lock_heartbeat_loop(interval, control = @heartbeat_control)
      crashes = 0
      loop do
        stopped = control.mutex.synchronize do
          control.cond.wait(control.mutex, interval) unless control.stopped
          control.stopped
        end
        break if stopped
        begin
          heartbeat
          crashes = 0
        rescue SignalException, SystemExit
          raise
        rescue Exception => error # rubocop:disable Lint/RescueException
          crashes += 1
          thread_error(error, 'Lock heartbeat')
          if crashes >= MAX_HEARTBEAT_CRASHES
            say "Lock heartbeat stopped after #{crashes} consecutive failures (last: #{error.class}: #{error.message}); " \
                "the locks of running jobs are no longer refreshed and expire after lock_timeout (#{Worker.lock_timeout}s)", 'error'
            break
          end
          say "Lock heartbeat failed with #{error.class}: #{error.message}; retrying in #{interval}s " \
              "(#{crashes}/#{MAX_HEARTBEAT_CRASHES})", 'error'
        end
      end
    end

    # Names whose locks to refresh: all but those running a job past its
    # max_run_time. One that ignored its timeout (e.g. stuck in native code)
    # would otherwise hold its lock forever; now another worker may take it.
    def heartbeat_names
      now = monotonic_now
      # The stuck slots with the snapshot: a stuck job ending meanwhile would
      # otherwise leave the next, healthy job's slot unrefreshed.
      overrun, stuck = synchronize do
        late = @jobs_started.select { |_worker, (_job, started, limit)| limit && now - started > limit }
        [late, late.keys.map { |worker| @running_slot[worker] }]
      end
      overrun.each { |worker, (job, _, limit, label)| report_overrun(worker, job, limit, label) }
      return (workers - overrun.keys).map(&:name) if @prefetch.zero?
      # Release jobs queued behind a stuck one (none are added, see #free_slots).
      release_queued(overrun.keys.map { |worker| @inboxes[worker] }.compact, :stuck)
      # With prefetch, refresh the slots holding jobs, except overrun ones.
      synchronize { (@slot_jobs.keys - stuck).map(&:name) }
    end

    # Jobs a poll locked but won't dispatch (a thread crashed meanwhile):
    # their slots were free, so their names hold nothing else.
    def release_reserved(reserved)
      return if reserved.empty?
      with_executor { Delayed::Job.clear_locks!(reserved.map { |slot, _job| slot.name }) }
    rescue StandardError => error
      say "Could not release the jobs reserved for a crashed worker: #{error.class}: #{error.message}", 'error'
    end

    # Records the refresh for slots still holding the same job (see #lock_time_left).
    def beaten(held, beat_at)
      synchronize do
        @last_beat_at = beat_at
        held.each { |slot, job| @slot_refreshed[slot] = beat_at if @slot_jobs[slot].equal?(job) }
      end
    end

    # Logs once per job, if it still runs (it may have ended since the
    # heartbeat looked).
    def report_overrun(worker, job, limit, label)
      first = synchronize do
        started = @jobs_started[worker]
        next false unless started && started[0].equal?(job) && !started[4]
        started[4] = true
      end
      return unless first
      # On the heartbeat thread: use the precomputed label; read only plain
      # fields (id, queue) of :job.
      Delayed.instrument(:job_stuck, :job => job, :job_name => label, :worker => worker.name,
                                     :max_run_time => limit, :lock_timeout => Worker.lock_timeout)
      worker.say(format('%s has run for longer than its max_run_time (%ds) without stopping; no longer ' \
                        'refreshing its lock, so another worker may run it after lock_timeout (%gs)',
                        label, limit, Worker.lock_timeout), 'error')
    end

    # Clears the #job_timed record after the block.
    def untrack_job_after(worker)
      yield
    ensure
      synchronize { @jobs_started.delete(worker) }
    end

    # How Worker#job_say names the job.
    def job_label(job)
      "Job #{job.name} (id=#{job.id})#{" (queue=#{job.queue})" if job.queue}"
    rescue StandardError
      "Job (id=#{job.id})"
    end

    # Errors are logged; locks expire only if heartbeats fail for lock_timeout.
    def heartbeat
      beat_at = monotonic_now # No later than the locks are refreshed.
      names = heartbeat_names
      return if names.empty?
      # Taken before the refresh, so every job listed is covered by it.
      wanted = names.to_set
      held = synchronize { @slot_jobs.select { |slot, _job| wanted.include?(slot.name) } }
      polling { Delayed::Job.touch_locks(names) }
      beaten(held, beat_at)
    rescue StandardError => error
      say "Error while refreshing job locks: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Lock heartbeat')
    end

    # Recorded one by one, so a failed start still stops earlier threads (see #run).
    def start_threads
      build_slots
      @threads = []
      workers.each_with_index do |worker, index|
        inbox = @inboxes[worker] = Inbox.new
        @threads << spawn_thread("delayed_job worker:#{index}") { work(worker, inbox) }
      end
    end

    # Threads report their own errors (see #thread_error).
    def spawn_thread(name, &block)
      Thread.new(&block).tap do |thread|
        thread.report_on_exception = false
        thread.name = name
      end
    end

    # With prefetch, one slot per job a worker may hold; else the worker itself.
    def build_slots
      Worker.validate_prefetch!
      @prefetch = Worker.prefetch
      @depth = Worker.prefetch_dynamic ? 0 : @prefetch
      workers.each do |worker|
        slots = if @prefetch.zero? then [worker]
        else Array.new(@prefetch + 1) { |index| Worker.named(Worker.slot_name(worker.name, index)) }
        end
        @slots[worker] = slots
        slots.each { |slot| @slot_owner[slot] = worker }
      end
    end

    # Worker thread body. Shutdown interrupts are deferred except while a job's
    # own code runs (Worker#run, .interruptible): elsewhere they could break
    # bookkeeping, :execute callbacks (ClearLocks), or a finishing job's
    # delete, so the job would be released and run again.
    def work(worker, inbox)
      Thread.current[:delayed_job_worker_thread] = true
      self.class.deferring_interrupts do
        Worker.lifecycle.run_callbacks(:execute, worker) do
          work_jobs(worker, inbox)
        rescue *SHUTDOWN_INTERRUPTS
          raise
        rescue Exception => error # rubocop:disable Lint/RescueException
          crashed(worker, error) # Before ClearLocks unlocks its job (see #poll_loop).
          raise
        ensure
          clear_slot_locks(worker)
        end
      end
    rescue *SHUTDOWN_INTERRUPTS
      # Deferred and delivered on exit, or a signal that escaped a job: the
      # process is stopping, so this is no crash.
      synchronize { @running.delete(Thread.current) }
    rescue Exception => error # rubocop:disable Lint/RescueException
      crashed(worker, error)
    end

    # Records a worker thread's crash, once: the poll loop then stops.
    def crashed(worker, error)
      first = synchronize do
        next false if @dead.include?(worker)
        @running.delete(Thread.current)
        retire(worker)
        @thread_error ||= error
        signal_event
        true
      end
      thread_error(error, 'Worker thread', worker.name) if first
    end

    def work_jobs(worker, inbox)
      until (item = inbox.pop).equal?(Inbox::EOQ)
        slot, job, reserved_at = item
        discard_stale_interrupts
        lock_left = lock_time_left(slot, reserved_at)
        reason = start_job(worker, slot, job, lock_left)
        reason ? release_unstarted(worker, slot, job, reason) : run_job(worker, slot, job, lock_left)
      end
    end

    # Registers the job as running, unless it mustn't start: returns why not
    # (see UNSTARTED_REASONS). Under the lock #stop_threads reads @running
    # under, so a quit landing just before can't miss the job.
    def start_job(worker, slot, job, lock_left)
      synchronize do
        next stop_reason if past_shutdown_deadline? || (@prefetch > 0 && stop?)
        next :lock_expired if lock_left && lock_left <= 0
        @running[Thread.current] = job
        @running_slot[worker] = slot
        nil
      end
    end

    # A job interrupted by shutdown is released.
    def run_job(worker, slot, job, lock_left)
      result = with_reloader { untrack_job_after(worker) { worker.perform_job(job, lock_left) } }
      synchronize { @running.delete(Thread.current) }
      job_finished(worker, slot, result)
    rescue *SHUTDOWN_INTERRUPTS => error
      synchronize do
        @running.delete(Thread.current)
        @running_slot.delete(worker)
      end
      release_interrupted(worker, job, error, slot)
    end

    # Seconds until the slot's lock expires (the job must stop by then, or
    # another worker may take it over), or nil for no limit: while the
    # heartbeat is alive, or without heartbeats if the job waited under 1s.
    def lock_time_left(slot, reserved_at)
      refreshed = synchronize { @slot_refreshed[slot] } || reserved_at
      waited = monotonic_now - refreshed
      left = Worker.lock_expiry - waited
      return left if left <= 0 # Expired.
      return nil if heartbeat_alive?
      return nil if waited < 1 && !Worker.lock_heartbeats?
      left >= 1 ? left.floor : left
    end

    # Running and refreshed within lock_timeout: not given up, and no refresh
    # hung that long.
    def heartbeat_alive?
      return false unless Worker.lock_heartbeats? && @heartbeat && @heartbeat.alive?
      synchronize { @last_beat_at && monotonic_now - @last_beat_at < Worker.lock_timeout }
    end

    # On thread exit, with prefetch: clears locks left under the worker's slot
    # names (e.g. after a failed release), as ClearLocks does for its own name.
    def clear_slot_locks(worker)
      return if @prefetch.zero?
      names = @slots[worker].map(&:name)
      with_executor { Delayed::Job.clear_locks!(names) }
    rescue StandardError => error
      say "Could not release the jobs of #{worker.name}: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs', worker.name)
    end

    # Under the mutex, after a thread crash: frees its slots (locks cleared in
    # #clear_slot_locks) and stops feeding it.
    def retire(worker)
      @dead << worker
      @running_slot.delete(worker)
      (@slots[worker] || [worker]).each { |slot| free_slot(slot) }
    end

    # Drops shutdown interrupts meant for the previous job. Stops after a pass
    # that delivers none, so a stuck pending one can't make it spin.
    def discard_stale_interrupts
      while stale_interrupt_pending?
        begin
          self.class.interruptible { Thread.pass }
          return # Pending but undelivered: leave it.
        rescue ShutdownInterrupt, SignalException
          nil
        end
      end
    end

    def stale_interrupt_pending?
      return false unless self.class.interrupt_masking? # Nothing is deferred.
      return Thread.pending_interrupt? unless self.class.pending_interrupt_by_class?
      SHUTDOWN_INTERRUPTS.any? { |klass| Thread.pending_interrupt?(klass) }
    end

    # Reports non-job errors (Worker.on_thread_error); job errors use :error.
    def thread_error(error, context, worker_name = nil)
      Worker.thread_error(error, :context => context, :dispatcher => name, :worker => worker_name)
    end

    # Runs a polling query in the executor, silenced if Worker.silence_logging.
    def polling(&block)
      return with_executor(&block) unless Worker.silence_logging
      with_executor { Delayed::Job.silence_logging(&block) }
    end

    # Signals, exits, and a re-raised worker thread crash: not failures.
    def stopping_error?(error)
      error.is_a?(SignalException) || error.is_a?(SystemExit) || error.equal?(@thread_error)
    end

    # Dispatcher thread only.
    def update_procline
      return unless @procline_name
      title = procline
      return if title == @procline_title
      @procline_title = title
      $0 = title
    end

    def queue_names
      queues = Worker.queues
      queues.nil? || queues.empty? ? '*' : queues.join(',')
    end

    def process_payload
      {:dispatcher => name, :pid => Process.pid, :threads => thread_count, :queues => Worker.queues,
       :prefetch => Worker.prefetch, :prefetch_dynamic => !!Worker.prefetch_dynamic}
    end

    # Lets running jobs finish, interrupting and releasing those still running
    # at #shutdown_deadline. A signal exception is raised in running jobs too.
    def stop_threads(error)
      # Also when the loop ended without #stop (exit_on_complete, crashed thread).
      @stop_requested_at ||= monotonic_now
      @stopped = true
      update_procline
      late_signal = nil
      begin
        # Defer a late signal until every inbox is closed: on JRuby one raised
        # in Queue#push surfaces as a ThreadError and leaves an inbox open.
        self.class.deferring_interrupts do
          release_queued(@inboxes.values, stop_reason) if @prefetch > 0
          @inboxes.each_value(&:close)
        end
        raise_in_threads(error) if error.is_a?(SignalException)
        wait_for_threads
      rescue SignalException => late_signal # rubocop:disable Naming/RescuedExceptionsVariableName -- `error` is the parameter
        # On JRuby the trap's stop can end the poll loop before its signal
        # reaches this thread (see #raise_signal): raise it in running jobs as
        # if it came first, finish stopping, then re-raise.
        raise_in_threads(late_signal)
        wait_for_threads
      end
      if shutdown_deadline
        # One grace for both: waiting it twice for a stuck job would let the
        # parent's kill (SHUTDOWN_GRACE) beat this process's own exit.
        grace_ends = monotonic_now + INTERRUPT_GRACE
        interrupt_threads(synchronize { @running.keys.select(&:alive?) }, grace_ends)
        # Also join idle threads: they may be releasing a late job and must run
        # :execute callbacks (ClearLocks) before process exit kills them.
        join_threads(grace_ends)
      end
      raise late_signal if late_signal
    end

    QUEUED_RELEASE_REASONS = {
      :shutdown => ['on shutdown', 'shutdown'],
      :promotion => ['on promotion to mold', 'promotion'],
      :stuck => ['queued behind a job that overran its max_run_time', 'stuck job']
    }.freeze

    # Releases jobs queued in `inboxes` unstarted: unlocked, attempts unchanged.
    def release_queued(inboxes = @inboxes.values, reason = :shutdown)
      queued = inboxes.flat_map(&:drain)
      return if queued.empty?
      message, event_reason = QUEUED_RELEASE_REASONS.fetch(reason)
      names = queued.map { |slot, _job| slot.name }
      with_executor { Delayed::Job.clear_locks!(names) }
      say "Released #{queued.size} queued job(s) #{message}", reason == :stuck ? 'warn' : 'info'
      Delayed.instrument(:jobs_released, :workers => names, :count => queued.size, :reason => event_reason)
    rescue StandardError => error
      say "Could not release the queued jobs: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs')
    ensure
      slots_done((queued || []).map(&:first))
    end

    def join_threads(deadline)
      @threads.each { |thread| thread.join([deadline - monotonic_now, 0].max) }
    end

    # Only into threads running a job: an idle one that just started could be
    # killed before its :execute callbacks (ClearLocks) run, leaving locks.
    def raise_in_threads(signal_exception)
      busy = synchronize { @running.keys }
      busy.each { |thread| thread.raise(signal_exception.class, signal_exception.message) if thread.alive? }
    end

    # Rechecks the deadline on each wait so #quit takes effect at once.
    def wait_for_threads
      loop do
        update_procline
        busy = @threads.find(&:alive?)
        break unless busy
        deadline = shutdown_deadline
        remaining = deadline && deadline - monotonic_now
        break if remaining && remaining <= 0
        busy.join(remaining ? [remaining, 0.1].min : 0.1)
      end
    end

    def interrupt_threads(busy, deadline)
      return if busy.empty?
      reason = quit? ? 'Quitting' : format('Shutdown timeout of %gs exceeded', Worker.shutdown_timeout)
      say "#{reason}: interrupting #{busy.size} running job(s)", 'warn'
      Delayed.instrument(:jobs_interrupted, :dispatcher => name, :jobs => busy.size, :reason => reason)
      busy.each { |thread| thread.raise(ShutdownInterrupt, reason) }
      # All interrupted before any is waited for.
      busy.each { |thread| thread.join([deadline - monotonic_now, 0].max) } # rubocop:disable Style/CombinableLoops
      stuck = busy.count(&:alive?)
      return if stuck.zero?
      say format('%<stuck>d job(s) did not stop within %<grace>gs of being interrupted; ' \
                 'leaving them locked until max_run_time expires', :stuck => stuck, :grace => INTERRUPT_GRACE), 'error'
    end

    # Now after #quit, shutdown_timeout after #stop, else never (nil).
    def shutdown_deadline
      return monotonic_now if quit?
      timeout = Worker.shutdown_timeout
      @stop_requested_at + timeout if timeout
    end

    # Clears the lock, attempts unchanged; with Worker.count_shutdown_interrupts,
    # records a failed attempt instead.
    def release_interrupted(worker, job, interrupt, slot)
      release_slot(worker, slot, 'shutdown') do
        # A promotion only saves memory: it never costs the job an attempt.
        if Worker.count_shutdown_interrupts && !promoted?
          worker.job_say(job, 'interrupted by shutdown; counted as a failed attempt', 'warn')
          worker.fail_attempt(job, interrupt)
        else
          worker.job_say(job, 'interrupted by shutdown; released for another worker', 'warn')
        end
      end
    end

    # Runs the block, clears the slot's lock, publishes jobs_released; always
    # frees the slot.
    def release_slot(worker, slot, event_reason)
      yield
      Delayed::Job.clear_locks!(slot.name)
      Delayed.instrument(:jobs_released, :workers => [slot.name], :count => 1, :reason => event_reason)
    rescue StandardError => error
      say "Could not release the jobs of #{slot.name}: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs', worker.name)
    ensure
      slots_done([slot])
    end

    def dispatch(slot, job, reserved_at = monotonic_now)
      synchronize { @slot_jobs[slot] = job }
      @inboxes[@slot_owner.fetch(slot, slot)].push(slot, job, reserved_at)
    end

    UNSTARTED_REASONS = {
      :shutdown => ['not started before shutdown', 'shutdown'],
      :promotion => ['not started before promotion to mold', 'promotion'],
      :lock_expired => ['waited in its queue until its lock expired', 'lock expired in queue']
    }.freeze

    # Releases a never-started job, attempts unchanged: on shutdown, or after
    # its lock expired while queued (it may already be taken over).
    def release_unstarted(worker, slot, job, reason = :shutdown)
      message, event_reason = UNSTARTED_REASONS.fetch(reason)
      release_slot(worker, slot, event_reason) { worker.job_say(job, "#{message}; released for another worker", 'warn') }
    end

    def stop_reason
      promoted? ? :promotion : :shutdown
    end

    def past_shutdown_deadline?
      deadline = stop? && shutdown_deadline
      deadline ? monotonic_now >= deadline : false
    end

    def job_finished(worker, slot, result)
      synchronize do
        result ? @success += 1 : @failure += 1
        @performed += 1
        @running_slot.delete(worker)
      end
      slots_done([slot])
    end

    # Under the mutex.
    def free_slot(slot)
      @slot_refreshed.delete(slot)
      @slot_jobs.delete(slot)
    end

    # Frees the slots and wakes the dispatcher to refill them.
    def slots_done(slots)
      synchronize do
        slots.each { |slot| free_slot(slot) }
        signal_event
      end
    end

    # `seen` is the event count read before deciding to wait, so no event is
    # missed. Returns false on timeout.
    def wait_for_event(seen, timeout)
      synchronize do
        @cond.wait(@mutex, timeout) if @events == seen && !stop?
        @events != seen || stop?
      end
    end

    def signal_event
      @events += 1
      @cond.broadcast
    end

    def wake_up
      synchronize { @cond.broadcast }
    rescue ThreadError
      # A Mutex can't be locked in a signal trap: wake from another thread.
      Thread.new { wake_up }
    end

    def snapshot
      synchronize { [free_slots, @events] }
    end

    # Taken in rounds: one per idle worker first, so urgent jobs start at once,
    # then one more per worker, up to the queue depth plus the running job.
    def free_slots
      # Skip workers stuck behind an overrun job (see #heartbeat_names).
      plan = (workers - @dead - overrun_workers).map do |worker|
        slots = @slots[worker] || [worker]
        held = slots.count { |slot| @slot_jobs.key?(slot) }
        [slots.reject { |slot| @slot_jobs.key?(slot) }, held]
      end
      (0..@depth).each_with_object([]) do |round, free|
        plan.each do |open, held|
          slot = round >= held && open[round - held]
          free << slot if slot
        end
      end
    end

    # Under the mutex.
    def overrun_workers
      @jobs_started.select { |_worker, started| started[4] }.keys
    end

    # Under the mutex.
    def busy_count
      workers.count { |worker| (@slots[worker] || [worker]).any? { |slot| @slot_jobs.key?(slot) } }
    end

    def finished_since?(seen)
      synchronize { @events != seen }
    end

    # Running or queued.
    def in_flight
      synchronize { @slot_jobs.size }
    end

    def completed
      synchronize { @success + @failure }
    end

    def report
      success, failure, elapsed = synchronize do
        stats = [@success, @failure, monotonic_now - @stats_started]
        reset_stats
        stats
      end
      count = success + failure
      return if count.zero?
      say format("#{count} jobs processed at %.4f j/s, %d failed", count / elapsed, failure)
    end

    def reset_stats
      @success = 0
      @failure = 0
      @stats_started = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def raise_thread_error
      error = synchronize { @thread_error }
      raise error if error
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    # Reloads code in development and manages connections across threads.
    def with_reloader(&block)
      app = rails_application
      app && app.respond_to?(:reloader) ? app.reloader.wrap(&block) : yield
    end

    def with_executor(&block)
      app = rails_application
      app && app.respond_to?(:executor) ? app.executor.wrap(&block) : yield
    end

    def rails_application
      ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
    end

    def warn_if_connection_pool_too_small
      return unless defined?(::ActiveRecord::Base)
      pool_size = ::ActiveRecord::Base.connection_pool.size
      needed = connections_needed
      return if pool_size >= needed
      say "WARNING: database connection pool size (#{pool_size}) is smaller than the #{needed} connections " \
          "this worker process may use at once (#{connection_users}). Increase the pool size in " \
          'config/database.yml.', 'warn'
    rescue StandardError
      nil
    end

    def connections_needed
      thread_count + 1 + (Worker.lock_heartbeats? ? 1 : 0)
    end

    def connection_users
      users = ["#{thread_count} job thread(s)", 'the dispatcher']
      users << 'the lock heartbeat' if Worker.lock_heartbeats?
      users.join(', ')
    end
  end
end
