require 'active_support/core_ext/class/attribute'
require 'concurrent/array'
require 'monitor'

module Delayed
  module Launcher
    class Forking < Base
      # Seconds past the shutdown timeout (or QUIT) before the parent SIGKILLs
      # workers, so they can interrupt and release their jobs.
      SHUTDOWN_GRACE = Delayed::Dispatcher::INTERRUPT_GRACE + 5

      # Exit status of a child process whose job threads didn't stop (a job
      # ignored its interrupt): not a clean exit, so the parent recovers the
      # jobs it held, counting a failed attempt.
      JOBS_STUCK = 76

      # A child dying within RESPAWN_MIN_UPTIME seconds is replaced after a
      # delay doubling per death in a row (up to RESPAWN_MAX_DELAY), so a
      # crash loop doesn't spin.
      RESPAWN_MIN_UPTIME = 10
      RESPAWN_MAX_DELAY = 60

      # First respawn delay in seconds; tests lower it.
      class_attribute :respawn_delay_unit, :instance_writer => false, :default => 1

      # Seconds between child process pings in mold mode; tests lower it.
      class_attribute :mold_ping_interval, :instance_writer => false, :default => 5

      # options[:pid_file]: true for a pidfile named after this process in
      # options[:pid_dir], or a String path.
      def initialize(options)
        pid_file = options.delete(:pid_file)
        super
        @pid_file = pid_file
        # Created eagerly: signal traps can't lazily init safely.
        @stop_signals = Concurrent::Array.new
        @child_signals = Concurrent::Array.new
      end

      def launch
        @stopped = !!@options[:exit_on_complete]
        @killed = false
        stop_signals.clear
        Delayed::Worker.validate_settings!(@options)
        validate_mold! if molding?
        setup_logger
        warn_mold_ignored
        setup_pidfile
        begin
          if forking? && !fork_available?
            raise NotImplementedError, 'running several worker processes needs fork, which this platform (e.g. JRuby) ' \
                                       'lacks: run one process per launcher, with --threads'
          end
          @launcher_pid = Process.pid
          trap_signals
          if forking?
            supervisor_pid
            prepare_for_fork
            Delayed::Worker.before_fork
          end
          setup_workers
          run_loop if forking?
          exit_forcefully if @killed
          before_graceful_exit
        ensure
          delete_pidfile
        end
      end

      # JRuby can't fork.
      def fork_available?
        Process.respond_to?(:fork)
      end

      # The pidfile's path, or nil.
      def pid_file
        return unless @pid_file
        return @pid_file.to_s unless @pid_file == true
        File.join(@options[:pid_dir], "#{get_name(process_identifier)}.pid")
      end

      def shutdown(timeout = nil)
        @stopped = true
        stop_signals << 'TERM' if stop_signals.empty?
        message = " with #{timeout} second grace period" if timeout
        logger.info "Shutdown invoked#{message}"
        signal_workers('TERM')
        schedule_kill(timeout) if timeout
      end

      # SIGKILLs the child processes (and molds), and only that: the run loop
      # reaps them, recovering their jobs as usual (a failed attempt), then
      # the launcher exits with status 1 (see #exit_forcefully).
      def kill(message = nil)
        @kill_message = message
        @stopped = true
        @killed = true
        stop_signals << 'KILL'
        logger.warn "Kill invoked#{" #{message}" if message}"
        signal_workers('KILL')
      end

      # Used by MoldSupervisor and Mold; not public API.

      def child_name(index)
        get_name(index)
      end

      def stopped?
        @stopped
      end

      # A stop signal arrived: no child process is started any more.
      def stopping?
        stop_signals.any?
      end

      # In a mold: forks the child process the parent asked for.
      def fork_mold_child(worker_index, pool_index, generation, close_ios)
        options = pool_index == Mold::NO_POOL ? @options : @options.merge(:queues => pools[pool_index].first)
        child_signals.clear # Before forking: the child's traps append to it.
        mold_pid = Process.pid
        fork do
          pending_signals = capture_signals
          close_ios.each(&:close)
          %w[CHLD URG].each { |signal| Signal.trap(signal, 'DEFAULT') }
          @mold_generation = @known_generation = generation
          @child_index = worker_index
          @forked_by_mold = mold_pid
          run_worker(get_name(worker_index), options, pending_signals)
        end
      end

      # Starts a child process, retrying with back-off if fork fails (EAGAIN,
      # ENOMEM, e.g. near a container's limits), the initial ones included.
      def add_worker_safely(options, replaces_pid = nil)
        add_worker(options, :replaces_pid => replaces_pid)
      rescue SystemCallError => error
        fork_failed(error, options, replaces_pid)
      end

      # Forks a requested child process here, retrying with back-off if fork
      # fails.
      def start_child_safely(index, options, spawn)
        start_child(options, spawn, index)
      rescue SystemCallError => error
        fork_failed(error, options, spawn[:replaces_pid])
      end

    private

      def trap_signals
        trap_shutdown_signal('INT')
        trap_shutdown_signal('TERM')
        trap_quit_signal if Signal.list.key?('QUIT')
        trap_hangup_signal if forking? && Signal.list.key?('HUP')
        # Signal-trap safe: the run loop promotes.
        Signal.trap('URG') { @mold_supervisor&.request_promotion unless forked_child? } if molding?
      end

      # HUP stops workers gracefully (forwarded as TERM). By default it would
      # kill the parent and delete its pidfile while workers still run,
      # letting a second launcher start beside them.
      def trap_hangup_signal
        Signal.trap('HUP') do
          next if forked_child?
          Thread.new { logger.info('Received SIGHUP. Waiting for workers to finish current job...') }
          stop_from_trap('TERM', kill_after_shutdown_timeout)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGHUP on this platform (#{error.message})"
      end

      # Forwards the signal to workers: docker stop, Kubernetes and systemd
      # (KillMode=process) signal only the parent.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          next child_signal(signal) if forked_child?
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          stop_from_trap(signal, kill_after_shutdown_timeout)
        end
      end

      # QUIT interrupts running jobs. The JVM reserves QUIT for thread dumps.
      def trap_quit_signal
        Delayed.check_trappable!('QUIT')
        Signal.trap('QUIT') do
          next child_signal('QUIT') if forked_child?
          Thread.new { logger.info('Received SIGQUIT. Interrupting running jobs...') }
          stop_from_trap('QUIT', SHUTDOWN_GRACE)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGQUIT on this platform (#{error.message}); use TERM or INT to stop"
      end

      # Signal-trap safe: takes no lock and doesn't log.
      def stop_from_trap(signal, kill_after)
        @stopped = true
        stop_signals << signal unless stop_signals.include?(signal)
        forward_signal(signal)
        schedule_kill(kill_after) if kill_after
      end

      def kill_after_shutdown_timeout
        timeout = shutdown_timeout
        timeout + SHUTDOWN_GRACE if timeout
      end

      # Signal-trap safe: doesn't log.
      def forward_signal(signal)
        # A copy: the run loop may remove workers meanwhile.
        workers.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
        @mold_supervisor&.signal_molds(signal) # A stopping mold exits once its children have.
      end

      def shutdown_timeout
        @options.fetch(:shutdown_timeout, Delayed::Worker.shutdown_timeout)
      end

      def workers
        @workers ||= {}
      end

      # Signals that stopped the launcher, in order. Appended to, never
      # replaced, so traps can use it.
      attr_reader :stop_signals

      # Passes the same list, so a signal arriving before the dispatcher's
      # traps replace the launcher's isn't lost.
      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Dispatcher.new(@options.merge(:procline => $0)).start(stop_signals)
      end

      # Starts a child process: forked here, or asked of the active mold
      # (returning nil; see MoldSupervisor). Returns nil once a stop signal
      # has arrived (e.g. while booting, before any child existed to forward
      # it to).
      def add_worker(options, replaces_pid: nil, delay: 0, streak: nil)
        return if stop_signals.any?
        return if replaces_pid && @mold_supervisor && !@mold_supervisor.replacement_needed?(replaces_pid)
        spawn = {:replaces_pid => replaces_pid, :delay => delay, :streak => streak}
        return start_child(options, spawn) unless @mold_supervisor&.forking_from_mold?
        index = @worker_index
        @worker_index += 1
        @mold_supervisor.request_fork(index, options, spawn)
      end

      # Forks a child process here, named after `index` (by default the next
      # one, used up only once forked).
      def start_child(options, spawn, index = nil)
        return if stop_signals.any?
        worker_name = get_name(index || @worker_index)
        pid = fork_worker(worker_name, options)
        @worker_index += 1 unless index
        child_started(worker_name, pid, options, spawn)
      end

      # Records a forked child process. `spawn`: :replaces_pid, :delay,
      # :streak (respawns in a row), and :mold_pid when a mold forked it.
      def child_started(worker_name, worker_pid, options, spawn)
        log_child_started(worker_name, worker_pid, options, spawn[:mold_pid])
        workers[worker_pid] = [worker_name, options]
        started_at[worker_pid] = monotonic_now
        respawn_streaks[worker_pid] = spawn[:streak] if spawn[:streak]
        @mold_supervisor&.child_started(worker_pid, spawn)
        Delayed.instrument(:process_spawned, {:worker => worker_name, :pid => worker_pid, :replaces_pid => spawn[:replaces_pid],
                                              :delay => spawn[:delay] || 0}.merge(spawn.slice(:mold_pid, :generation).compact))
        catch_up_on_stop(worker_pid)
        worker_pid
      end

      def log_child_started(worker_name, worker_pid, options, mold_pid)
        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        thread_msg = " threads=#{threads(options)}" if threads(options) > 1
        mold_msg = " from mold (pid #{mold_pid})" if mold_pid
        logger.info "Child process #{worker_name} (pid #{worker_pid}) started#{mold_msg}#{queue_msg}#{thread_msg}"
      end

      # A stop signal arriving after #add_worker's check was forwarded only
      # to children recorded then; send it to this one too.
      def catch_up_on_stop(pid)
        signal = stop_signals.last
        return unless signal
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      def fork_worker(worker_name, options)
        generation = @mold_supervisor&.generation
        fork do
          @known_generation = generation
          pending_signals = capture_signals
          run_worker(worker_name, options, pending_signals)
        end
      end

      # Replaces the parent's inherited traps (which would signal sibling
      # workers) with ones that only record signals, so a signal arriving
      # while the worker boots isn't lost.
      def capture_signals
        # Same list, not a copy: an inherited trap may still fire until
        # replaced below.
        pending = child_signals
        %w[TERM INT QUIT].each do |signal|
          next unless Signal.list.key?(signal)
          # Deduped: may arrive via the process group and the parent.
          begin
            Delayed.check_trappable!(signal)
            Signal.trap(signal) { pending << signal unless pending.include?(signal) }
          rescue ArgumentError
            nil # Can't be trapped here (QUIT on the JVM); the dispatcher warns.
          end
        end
        # The parent forwards HUP as TERM (see #trap_hangup_signal).
        # A handler, not 'IGNORE': an ignored signal stays ignored across exec,
        # in commands jobs run.
        Signal.trap('HUP') {} if Signal.list.key?('HUP') # rubocop:disable Lint/EmptyBlock
        pending
      end

      # True in a forked child still running the inherited launcher traps.
      def forked_child?
        @launcher_pid && Process.pid != @launcher_pid
      end

      # An inherited trap in a child only records the signal: it must not
      # stop the child's launcher copy or signal siblings.
      def child_signal(signal)
        child_signals << signal unless child_signals.include?(signal)
      end

      # Concurrent::Array: JRuby runs traps on parallel threads. On CRuby
      # it's a plain Array, safe in a trap (a Mutex isn't).
      attr_reader :child_signals

      # Written first, so a second launcher exits before booting workers.
      def setup_pidfile
        return unless pid_file
        @pidfile = Delayed::Pidfile.new(pid_file)
        @pidfile.setup
        logger.info "Wrote pidfile #{pid_file} - pid #{$$}"
      end

      def delete_pidfile
        @pidfile.delete if @pidfile
      end

      # Forked workers stop if this process (their parent) goes away.
      def supervisor_pid
        @supervisor_pid ||= Process.pid
      end

      def run_loop
        return run_mold_loop if @mold_supervisor
        loop do
          worker_pid, child_status = wait_for_child
          handle_exit(worker_pid, child_status) if worker_pid
          replace_due_workers
          break if @stopped && workers.empty?
        end
      rescue Errno::ECHILD
        logger.warn 'No child processes found'
      end

      def exit_forcefully
        logger.warn "#{parent_name} exited forcefully#{" #{@kill_message}" if @kill_message} - pid #{$$}"
        exit(1)
      end

      # Polls: children forked by a mold are reported by it, and, without a
      # subreaper, molds and their orphans aren't this process's to wait for.
      def run_mold_loop
        loop do
          mold_loop_pass
          break if @stopped && workers.empty? && @mold_supervisor.done?
        end
      end

      # An unexpected error is reported, not raised: the launcher going away
      # would stop every child process.
      def mold_loop_pass
        reap_children
        @mold_supervisor.tick
        replace_due_workers
      rescue StandardError => error
        logger.error "Mold supervisor error: #{error.class}: #{error.message}"
        Delayed::Worker.thread_error(error, :context => 'Mold supervisor')
        sleep 0.1 # No busy loop if it keeps failing.
      end

      # Direct children, and orphans reparented here (subreaper or PID 1),
      # e.g. molds, a dead mold's children, and processes jobs left behind.
      def reap_children
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break unless pid
          next if @mold_supervisor.reaped(pid)
          next if handle_exit(pid, status)
          logger.debug "Reaped process (pid #{pid}) exited: #{status}"
        end
      rescue Errno::ECHILD
        nil
      end

      # Returns [pid, status], or nil when a pending replacement falls due or
      # the launcher stops.
      def wait_for_child
        return Process.wait2 if pending_replacements.empty?
        loop do
          begin
            exited = Process.wait2(-1, Process::WNOHANG)
            return exited if exited
          rescue Errno::ECHILD
            nil # All children are waiting to be replaced.
          end
          remaining = pending_replacements.map(&:first).min - monotonic_now
          return if @stopped || remaining <= 0
          sleep([remaining, 0.1].min)
        end
      end

      def handle_exit(worker_pid, child_status)
        worker_name, options = workers.delete(worker_pid)
        return false unless worker_name
        promoted = promoted_child?(worker_pid)
        # The supervisor fills the slot of a reforked or promoted child.
        replace = !@stopped && !@mold_supervisor&.child_exited(worker_pid, child_status, options)
        logger.info "Child process #{worker_name} (pid #{worker_pid}) exited: #{child_status}"
        recover_jobs_of_worker(worker_name, worker_pid, options, child_status, :promoted => promoted)
        publish_child_exited(worker_name, worker_pid, child_status, replace)
        warn_if_sigkilled(worker_name, worker_pid, child_status, replace)
        replace ? replace_worker(worker_name, worker_pid, options, child_status) : forget_child(worker_pid)
        true
      ensure
        @plans&.delete(worker_pid)
      end

      # Returns the new pid, or nil if delayed (see RESPAWN_MIN_UPTIME).
      def replace_worker(worker_name, pid, options, status)
        uptime, streak, delay = respawn_plan(pid)
        forget_child(pid)
        return respawn(worker_name, pid, options, status, streak, 0) unless delay
        logger.warn format('Child process %<name>s (pid %<pid>d) died %<uptime>.1fs after starting (%<streak>d time(s) in a row); ' \
                           'waiting %<delay>gs before replacing it',
                           :name => worker_name, :pid => pid, :uptime => uptime.to_f, :streak => streak, :delay => delay)
        pending_replacements << [monotonic_now + delay, [worker_name, pid, options, status, streak, delay]]
        nil
      end

      # Checked before the supervisor forgets it.
      def promoted_child?(pid)
        @mold_supervisor&.promoted?(pid) || false
      end

      def forget_child(pid)
        @plans&.delete(pid)
        started_at.delete(pid)
        respawn_streaks.delete(pid)
      end

      def warn_if_sigkilled(worker_name, pid, status, replace)
        return unless status.termsig == 9 && !@killed
        logger.warn "Child process #{worker_name} (pid #{pid}) was SIGKILLed (e.g. by the OOM killer)#{'; replacing it' if replace}"
      end

      # :respawn_in is nil when not replaced (or replaced by the mold
      # supervisor, e.g. a child promoted to mold).
      def publish_child_exited(worker_name, pid, status, replace)
        uptime, _streak, delay = respawn_plan(pid)
        respawn_in = replace ? delay || 0 : nil
        Delayed.instrument(:process_exited, :worker => worker_name, :pid => pid, :status => status, :uptime => uptime, :respawn_in => respawn_in)
      end

      # [uptime, streak, delay]; memoized per exit so the event and the
      # replacement agree.
      def respawn_plan(pid)
        (@plans ||= {})[pid] ||= begin
          started = started_at[pid]
          uptime = started && monotonic_now - started
          streak = uptime && uptime < RESPAWN_MIN_UPTIME ? respawn_streaks[pid].to_i + 1 : 0
          [uptime, streak, respawn_delay(streak)]
        end
      end

      def replace_due_workers
        return if pending_replacements.empty?
        return pending_replacements.clear if @stopped
        now = monotonic_now
        due, pending = pending_replacements.partition { |at, _| at <= now }
        @pending_replacements = pending
        due.sort_by(&:first).each { |_, replacement| respawn(*replacement) }
      end

      # A failed fork (EAGAIN, ENOMEM) is retried with back-off rather than
      # crashing the launcher.
      def respawn(worker_name, pid, options, status, streak, delay) # rubocop:disable Metrics/ParameterLists
        # Passed only when set: the mold forks it later, recording the streak then.
        new_pid = add_worker(options, :replaces_pid => pid, :delay => delay, **(streak > 0 ? {:streak => streak} : {}))
        respawn_streaks[new_pid] = streak if new_pid
        new_pid
      rescue SystemCallError => error
        retry_fork(error, [worker_name, pid, options, status], streak + 1)
      end

      # A fork outside #respawn failed: retried like a failed respawn.
      def fork_failed(error, options, replaces_pid)
        worker_name, = workers[replaces_pid]
        retry_fork(error, [worker_name || get_name(@worker_index), replaces_pid, options, nil], 1)
      end

      # Queues a replacement after a back-off (fork fails on EAGAIN, ENOMEM).
      # `replacement`: [worker_name, replaced pid, options, exit status].
      def retry_fork(error, replacement, streak)
        worker_name, pid, = replacement
        retry_delay = respawn_delay(streak)
        logger.error "Could not fork a replacement for child process #{worker_name} (pid #{pid.inspect}): " \
                     "#{error.class}: #{error.message}; retrying in #{retry_delay}s"
        Delayed::Worker.thread_error(error, :context => 'Forking', :worker => worker_name, :pid => pid)
        pending_replacements << [monotonic_now + retry_delay, replacement + [streak, retry_delay]]
        nil
      end

      def respawn_delay(streak)
        return if streak.zero?
        [respawn_delay_unit * 2**(streak - 1), RESPAWN_MAX_DELAY].min
      end

      # [[due_at, replacement_args], ...]
      def pending_replacements
        @pending_replacements ||= []
      end

      def started_at
        @started_at ||= {}
      end

      def respawn_streaks
        @respawn_streaks ||= {}
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Unlocks jobs a dead worker held, rather than waiting out max_run_time.
      # A crash counts as a failed attempt. A child promoted to mold that
      # forked none (PROMOTION_FAILED) gave up cleanly: a promotion never
      # costs a job an attempt.
      def recover_jobs_of_worker(worker_name, pid, options, status, promoted: false) # rubocop:disable Metrics/ParameterLists
        lock_names = Delayed::Worker.lock_names("#{worker_name} ", pid, threads(options), prefetch(options))
        # Clean exit: leftover locks are stale; release, attempts unchanged.
        return Delayed::Job.clear_locks!(lock_names) if status.success? || (promoted && status.exitstatus == Mold::PROMOTION_FAILED)
        count = Delayed::Worker.recover_jobs_of(lock_names, ProcessExitError.new(worker_name, pid, status))
        logger.warn "Recovered #{count} job(s) left locked by child process #{worker_name} (pid #{pid})" if count > 0
      rescue StandardError => error
        logger.error "Could not recover the jobs of child process #{worker_name} (pid #{pid}): #{error.class}: #{error.message}. " \
                     'Their locks will expire after max_run_time.'
        Delayed::Worker.thread_error(error, :context => 'Recovering jobs', :worker => worker_name, :pid => pid)
      ensure
        disconnect_backend
      end

      # So the next forked worker doesn't inherit recovery's connections.
      def disconnect_backend
        Delayed::Worker.backend.before_fork
      rescue StandardError => error
        logger.error "Could not disconnect from the database: #{error.class}: #{error.message}"
      end

      # No-op if a kill is already scheduled sooner. Signal-trap safe.
      def schedule_kill(timeout)
        at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        return if @kill_at && @kill_at <= at
        @kill_at = at
        Thread.new do
          sleep(timeout)
          kill("after #{timeout} second timeout")
          sleep(SHUTDOWN_GRACE)
          exit_stuck
        end
      end

      # Backstop: the run loop should exit soon after the kill; if it's stuck
      # (e.g. a hung database call), exit regardless. The pidfile is left
      # behind, harmless: its flock is what counts.
      def exit_stuck
        logger.error "#{parent_name} still running #{SHUTDOWN_GRACE}s after the kill; exiting - pid #{$$}"
        flush_and_exit!(1)
      end

      # Skips workers that already exited, so a kill isn't aborted.
      def signal_workers(signal)
        workers.dup.each do |pid, (worker_name, _)|
          Process.kill(signal, pid)
          logger.info "Sent SIG#{signal} to child process #{worker_name} (pid #{pid})"
        rescue Errno::ESRCH
          logger.info "Child process #{worker_name} (pid #{pid}) already exited; not sent SIG#{signal}"
        end
        @mold_supervisor&.signal_molds(signal)
      end

      def before_graceful_exit
        logger.info "#{parent_name} exited gracefully - pid #{$$}"
      end

      def parent_name
        "#{get_name(process_identifier)}#{' (parent)' if forking?}"
      end

      # Mirrors the branches of #setup_workers.
      def forking?
        return true if pools || molding?
        !process_identifier && processes > 1
      end

      # Mold mode forks child processes even for one.
      def multiple_processes?
        super || molding?
      end

      # Mold process (experimental; see Mold and MoldSupervisor).

      def mold_thresholds
        return @mold_thresholds if defined?(@mold_thresholds)
        @mold_thresholds = Delayed::Worker.mold_thresholds(@options.fetch(:mold, Delayed::Worker.mold))
      end

      # Off with exit_on_complete: it would never promote.
      def molding?
        !mold_thresholds.nil? && !@options[:exit_on_complete]
      end

      def warn_mold_ignored
        return unless mold_thresholds && @options[:exit_on_complete]
        logger.warn 'mold is ignored with exit_on_complete (workoff): child processes stop before any could be promoted'
      end

      def validate_mold!
        raise NotImplementedError, 'mold needs fork, which this platform (e.g. JRuby) lacks' unless fork_available?
        raise ArgumentError, 'mold cannot be used with --identifier' if process_identifier
      end

      # Pipes and supervisor exist before the first fork, so every child
      # process inherits the pipes. As a child subreaper (Linux), this
      # process adopts molds and their orphans, and waits for them.
      def setup_workers
        if molding?
          @mold_pipes = Mold::Pipes.new
          @reaps_orphans = Process.pid == 1 || ProcessUtil.enable_child_subreaper
          unless @reaps_orphans
            logger.warn 'Mold process: could not make the parent a child subreaper (needs Linux and the fiddle gem); ' \
                        "a mold's child processes will stop if it dies"
          end
          @mold_supervisor = MoldSupervisor.new(self, mold_thresholds, @mold_pipes, @reaps_orphans)
        end
        super
      end

      # In a child process: the parent's pipe ends aren't its to hold.
      def run_worker(*)
        @mold_supervisor = nil
        @mold_pipes&.close_parent_ends
        super
      end

      def set_process_name(name) # rubocop:disable Naming/AccessorMethodName
        super(@mold_generation.to_i > 0 ? "#{name} gen #{@mold_generation}" : name)
      end

      # In a child process. A promoted one stops like on TERM, then forks
      # its mold, if nothing is left running that a fork would freeze.
      #
      # Exiting cleanly with a job thread still running (its job ignored the
      # interrupt) would make the parent release its lock as stale, with no
      # attempt counted, though it was cut off mid-run: JOBS_STUCK instead.
      def run_dispatcher(worker_name, dispatcher, pending_signals)
        ping = boot_mold_child(dispatcher) if @mold_pipes
        dispatcher.start(pending_signals)
        ping&.kill&.join
        unless dispatcher.cleanly_stopped?
          logger.error "Child process #{worker_name} (pid #{Process.pid}) exiting with job thread(s) still running"
          flush_and_exit!(JOBS_STUCK)
        end
        finish_mold_child(worker_name, dispatcher) if @mold_pipes
      end

      # Returns the ping thread.
      def boot_mold_child(dispatcher)
        Signal.trap('URG') { dispatcher.promote }
        # After the trap: only booted children are promoted. Its index and
        # mold let the parent adopt it if the mold's "f" never comes.
        @mold_pipes.report("b #{Process.pid} #{@child_index || '-'} #{@forked_by_mold || '-'}")
        start_mold_ping(dispatcher)
      end

      def finish_mold_child(worker_name, dispatcher)
        flush_and_exit!(Mold::PROMOTION_FAILED) if dispatcher.promotion_cancelled? # The parent then retries.
        return unless dispatcher.promoted?
        child_signals.clear
        capture_signals # Signals now only recorded: the mold checks them.
        promote_to_mold(worker_name, dispatcher)
      end

      def start_mold_ping(dispatcher)
        Thread.new do
          loop do
            unsafe = Delayed::Worker.fork_safe? ? 0 : 1
            @mold_pipes.report("p #{Process.pid} #{dispatcher.jobs_performed} #{dispatcher.busy_threads} #{unsafe}", :blocking => false)
            sleep mold_ping_interval
          end
        end
      end

      # Exits with Mold::PROMOTION_FAILED (the parent then retries) instead
      # of forking a mold it shouldn't (with threads still running, it
      # exited JOBS_STUCK already).
      def promote_to_mold(worker_name, dispatcher)
        if !ProcessUtil.parent_alive?(supervisor_pid)
          logger.warn "Child process #{worker_name} (pid #{Process.pid}) promoted to mold: the parent is gone; not forking a mold"
        elsif !Delayed::Worker.fork_safe? # Since its last ping.
          logger.error "Child process #{worker_name} (pid #{Process.pid}) promoted to mold is no longer fork safe; not forking a mold"
        elsif child_signals.empty? && dispatcher.promoted?
          return fork_mold(worker_name)
        end
        flush_and_exit!(Mold::PROMOTION_FAILED)
      end

      # exit! skips at_exit, which would flush buffered log output.
      def flush_and_exit!(status)
        [$stdout, $stderr].each { |io| io.flush rescue nil }
        exit!(status)
      end

      # This process then exits, orphaning the mold; as a child subreaper,
      # the parent adopts it.
      def fork_mold(worker_name)
        Delayed::Worker.before_fork
        info = {:promoted_pid => Process.pid, :generation => @known_generation.to_i + 1, :exit_when_retired => @reaps_orphans}
        launcher_pid = @launcher_pid
        mold_pid = fork do
          run_mold(worker_name, info, launcher_pid)
        end
        @mold_pipes.report("M #{Process.pid} #{mold_pid}")
      end

      def run_mold(worker_name, info, launcher_pid)
        status = 0
        Mold.new(self, @mold_pipes, info).run do
          # Its children stop when their parent is gone; adopted by the
          # launcher (subreaper), they carry on when it dies.
          @supervisor_pid = @reaps_orphans ? [Process.pid, launcher_pid] : Process.pid
          @mold_generation = info[:generation]
          set_process_name("#{worker_name}: mold")
        end
      rescue Exception => error # rubocop:disable Lint/RescueException
        status = 1
        logger.error "Mold (pid #{Process.pid}) failed: #{error.class}: #{error.message}\n#{Array(error.backtrace).first(10).join("\n")}"
        Delayed::Worker.thread_error(error, :context => 'Mold', :pid => Process.pid) if error.is_a?(StandardError)
      ensure
        flush_and_exit!(status) # Not the dispatcher's at_exit hooks again.
      end

      public :workers, :handle_exit, :add_worker, :start_child, :child_started, :child_signal, :child_signals, :logger, :warmup_heap,
             :flush_and_exit!, :shutdown_timeout
    end
  end
end
