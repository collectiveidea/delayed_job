require 'active_support/core_ext/class/attribute'

module Delayed
  module Launcher
    # Mold process (experimental), parent side; see Mold. Created by the
    # forking launcher only with Worker.mold.
    #
    # A child process reaching the next threshold (or the busiest one, on
    # SIGURG to the parent) is promoted: it stops gracefully and forks a mold.
    # Once the mold is ready, child processes are reforked from it a few at a
    # time, each replacement booting before the child it replaces is stopped.
    # A mold that dies is replaced by another promotion; until then, the
    # parent forks child processes itself.
    class MoldSupervisor
      # Child process state tracked from status lines. `replaces`: the old
      # child a refork replacement takes over from, until it boots.
      Child = Struct.new(:mold_pid, :generation, :started_at, :replaces, :jobs, :busy,
                         :booted, :retiring, :promoted, :unsafe, :orphaned, :boot_timed_out, :keyword_init => true)

      # Seconds a mold may take to fork a requested child before it counts
      # as hung and is killed.
      MOLD_FORK_TIMEOUT = 30

      # Seconds from the promoted child's exit until its mold must be ready,
      # or (PROMOTION_FORK_TIMEOUT) must have been forked.
      MOLD_READY_TIMEOUT = 120
      PROMOTION_FORK_TIMEOUT = 5

      # Seconds, once stopping and every child process has exited, before
      # molds still running are killed (they run no jobs).
      MOLD_STOP_TIMEOUT = 10

      # Child processes forked by one mold that die before booting, in a row,
      # before that mold counts as broken.
      BOOT_FAILURE_LIMIT = 3

      # A mold living this long resets the promotion retry back-off.
      MOLD_STABLE_UPTIME = 600
      MAX_RETRY_DELAY = 600

      # Failed promotions (or lost molds) in a row before promotion stops
      # until SIGURG to the parent re-arms it.
      MAX_FAILURES = 5

      # Share of child processes reforked at once (at least one).
      REFORK_SHARE = 0.1

      # Seconds a child process may take to boot before it is killed.
      class_attribute :boot_timeout, :instance_writer => false, :default => 60
      # First promotion retry delay in seconds, doubling per failure.
      class_attribute :retry_delay_unit, :instance_writer => false, :default => 10
      # Seconds the promoted child may drain before its slot is refilled.
      class_attribute :drain_deadline, :instance_writer => false, :default => 300

      # Status line type => handler (see Mold::Pipes).
      STATUS_HANDLERS = {
        'b' => :child_booted, 'p' => :child_pinged, 'M' => :mold_forked, 'm' => :mold_ready,
        'f' => :mold_forked_child, 'e' => :mold_fork_failed, 'x' => :mold_reaped_child, 's' => :mold_stopping
      }.freeze

      attr_reader :generation

      # `launcher`: the Forking launcher (see its methods used by
      # MoldSupervisor); `reaps_orphans`: whether orphaned descendants are
      # reparented to it (child subreaper, or PID 1).
      def initialize(launcher, thresholds, pipes, reaps_orphans)
        @launcher = launcher
        @thresholds = thresholds
        @pipes = pipes
        @reaps_orphans = reaps_orphans
        @molds = {} # pid => :promoted, :active, :retired or :abandoned
        @generation = 0
        @threshold_index = 0
        @children = {} # pid => Child
        @early_boots = {} # pid => when it booted, before the parent recorded it
        @pending_forks = {} # worker index => {:options, :spawn, :at}
        @deferred_slots = [] # [options, replaces_pid] of promoted children
        @steps = {} # old pid => replacement pid (nil until forked)
        @failures = 0 # promotions failed (or molds lost) in a row
        @reaped = {} # pid => when: exited molds, and children reaped unknown
      end

      # Signal-trap safe.
      def request_promotion
        @promote_requested = true
      end

      def forking_from_mold?
        !@active_mold.nil?
      end

      # Asks the active mold to fork a child process; its pid is recorded
      # when the mold reports it.
      def request_fork(index, options, spawn)
        @pending_forks[index] = {:options => options, :spawn => spawn}
        send_fork_requests
        nil
      end

      def promoted?(pid)
        @children[pid]&.promoted || false
      end

      # False when the slot `replaces_pid` held is no longer to be filled:
      # its refork step was aborted, and it keeps its slot.
      def replacement_needed?(replaces_pid)
        info = @children[replaces_pid]
        !info || info.retiring || @steps.key?(replaces_pid)
      end

      def child_started(pid, spawn)
        # A child forked by a mold that isn't the active one (e.g. retiring)
        # has its memory, not the active mold's: reforked like a cold one.
        generation = spawn[:mold_pid] && spawn[:mold_pid] != @active_mold ? nil : spawn.fetch(:generation, @generation)
        info = Child.new(:mold_pid => spawn[:mold_pid], :generation => generation,
                         :started_at => monotonic_now, :jobs => 0, :busy => 0, :booted => false, :retiring => false,
                         :promoted => false, :unsafe => false, :orphaned => false)
        replaced = spawn[:replaces_pid]
        if replaced && @steps.key?(replaced)
          info.replaces = replaced
          @steps[replaced] = pid
        end
        @children[pid] = info
        mark_booted(info) if @early_boots.delete(pid)
      end

      # Returns true if the exited child process's slot is taken care of here
      # (held by another process, or refilled from its mold once ready), so
      # the launcher must not replace it.
      def child_exited(pid, status, options)
        info = @children.delete(pid)
        @early_boots.delete(pid)
        return false unless info
        step_failed = refork_step_failed(info)
        @steps.delete(pid) # An old child exiting mid-step: its replacement takes over.
        count_boot_failure(boot_failure(pid, info, status)) if failed_to_boot?(info, status)
        return promoted_exited(pid, status, options, info.retiring) if info.promoted
        info.retiring || step_failed
      end

      # Returns whether `pid` was a mold (reaped as this process's child).
      # Status lines are read after reaping, so a mold may be reaped before
      # its "M" or "m" is read: remembered, it isn't tracked then.
      def reaped(pid)
        unless @molds.key?(pid)
          @reaped[pid] = monotonic_now unless @launcher.workers.key?(pid)
          return false
        end
        mold_exited(pid)
        true
      end

      # One pass of the launcher's run loop.
      def tick
        @pipes.each_status(0.1) { |type, *args| handle_status(type, *args) }
        check_molds unless @reaps_orphans # Otherwise reaped as this process's children.
        check_orphans
        send_fork_requests
        check_timeouts
        handle_promotion_requests
        advance_refork
      end

      # No mold left and no fork pending.
      def done?
        @molds.empty? && @pending_forks.empty?
      end

      # Signal-trap safe.
      def signal_molds(signal)
        @molds.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

    private

      # Counted per mold: only the active mold's children.
      def failed_to_boot?(info, status)
        info.mold_pid && info.mold_pid == @active_mold && !info.booted && !status.success?
      end

      def logger
        @launcher.logger
      end

      # A malformed line (e.g. from a process of another version) is skipped.
      def handle_status(type, *args)
        handler = STATUS_HANDLERS[type]
        send(handler, *args) if handler && args.first.is_a?(Integer) # Every line starts with a pid.
      rescue ArgumentError, TypeError, NoMethodError => error
        logger.warn "Ignoring malformed mold status line #{[type, *args].join(' ').inspect}: #{error.message}"
      end

      # "b <pid> <worker index> <mold pid>": a child whose "f" isn't read yet
      # (or never will be: its mold died first) is adopted if its slot is
      # still pending; one the parent no longer wants is stopped.
      def child_booted(pid, index = nil, mold_pid = nil)
        info = @children[pid]
        return mark_booted(info) if info
        return @early_boots[pid] = monotonic_now unless index && mold_pid
        entry = @pending_forks.delete(index)
        return stop_stray(pid, mold_pid) unless entry
        @launcher.child_started(@launcher.child_name(index), pid, entry[:options], entry[:spawn].merge(:mold_pid => mold_pid))
        mark_booted(@children[pid]) if @children[pid]
      end

      def stop_stray(pid, mold_pid)
        logger.warn "Stopping child process (pid #{pid}) forked by mold (pid #{mold_pid}) after the parent gave up on it"
        signal(pid, 'TERM')
      end

      def child_pinged(pid, jobs, busy, unsafe = 0)
        info = @children[pid]
        return unless info
        mark_booted(info)
        info.jobs = jobs
        info.busy = busy
        info.unsafe = unsafe == 1
        threshold = @thresholds[@threshold_index]
        promote(:threshold) if threshold && jobs >= threshold && settled? && !held? && !@disabled
      end

      # A refork replacement booting completes its step: the old child stops.
      def mark_booted(info)
        return if info.booted
        info.booted = true
        @boot_failures = [] if info.mold_pid && info.mold_pid == @active_mold
        old = info.replaces
        return unless old && @steps.delete(old)
        info.replaces = nil
        signal(old, 'TERM')
      end

      # Every child process runs and is of the current generation: no
      # promotion, retry or refork in progress.
      def settled?
        !@launcher.stopped? && @promotion.nil? && @retry_trigger.nil? && refork_idle?
      end

      def refork_idle?
        @steps.empty? && @pending_forks.empty? && @deferred_slots.empty? &&
          @children.values.all? { |info| current?(info) && !info.retiring }
      end

      def current?(info)
        info.generation == @generation
      end

      def held?
        @hold_until && monotonic_now < @hold_until
      end

      # Promotes the child process with the most jobs performed, preferring
      # idle ones so promotion doesn't wait for long jobs.
      def promote(trigger)
        return if @launcher.stopped? || @promotion
        pid, info = promotion_candidate
        unless pid
          logger.warn('No child process to promote to mold') if trigger == :signal
          return
        end
        info.promoted = true
        @retry_trigger = nil
        @pss_before = total_pss_mb # With the promoted child still running.
        @promotion = {:pid => pid, :trigger => trigger, :at => monotonic_now}
        worker_name, = @launcher.workers[pid]
        logger.info "Promoting child process #{worker_name} (pid #{pid}) to mold after #{info.jobs} job(s) (#{trigger})"
        Delayed.instrument(:mold_promoted, :worker => worker_name, :pid => pid, :jobs => info.jobs, :trigger => trigger)
        signal(pid, 'URG')
      end

      def promotion_candidate
        @children.select { |_, info| promotable?(info) }.max_by { |_, info| [info.busy.zero? ? 1 : 0, info.jobs] }
      end

      def promotable?(info)
        info.booted && !(info.retiring || info.promoted || info.unsafe || info.orphaned)
      end

      # SIGURG is ignored while a promotion or refork is in progress, so
      # retired molds don't pile up; a pending retry runs once due.
      def handle_promotion_requests
        requested = @promote_requested
        @promote_requested = false
        if requested
          return logger.warn('Received SIGURG while a promotion or refork is in progress; ignoring it') if @promotion || !refork_idle?
          rearm if @disabled
          return promote(:signal)
        end
        promote(@retry_trigger) if @retry_trigger && !held?
      end

      def rearm
        logger.info 'Received SIGURG: promoting to mold again'
        @disabled = false
        @failures = 0
      end

      # Exited cleanly: it forked its mold (which may be ready already), and
      # its slot is refilled from the mold. Otherwise the promotion failed,
      # and the launcher replaces it as usual. `refilled`: its slot was
      # already refilled (see #refill_draining_slot). Returns whether the
      # slot is taken care of.
      def promoted_exited(pid, status, options, refilled)
        current = @promotion && @promotion[:pid] == pid
        unless status.success?
          promotion_failed(:child_exited, "Child process (pid #{pid}) promoted to mold exited with #{status}, forking no mold") if current
          return refilled
        end
        @promotion[:exited_at] = monotonic_now if current
        defer_slot(options, pid) unless refilled
        true
      end

      # Refilled from the new mold once ready.
      def defer_slot(options, pid)
        @deferred_slots << [options, pid] unless @launcher.stopped?
        refill_deferred_slots unless @promotion
      end

      def mold_forked(child_pid, mold_pid)
        return unless mold_pid
        return if @molds[mold_pid] == :active # Its "m" came first.
        return reaped_mold_reported(child_pid, mold_pid) if @reaped.key?(mold_pid)
        if promoting?(child_pid)
          @promotion[:mold_pid] = mold_pid
          @molds[mold_pid] ||= :promoted
        else
          abandon(mold_pid)
        end
      end

      def mold_ready(mold_pid, child_pid)
        return unless mold_pid
        return if @molds[mold_pid] == :active
        return reaped_mold_reported(child_pid, mold_pid) if @reaped.key?(mold_pid)
        return abandon(mold_pid) unless promoting?(child_pid) && [nil, :promoted].include?(@molds[mold_pid])
        activate(mold_pid)
      end

      # A mold that exited before its line was read: not tracked, and the
      # promotion it was for (if still current) failed.
      def reaped_mold_reported(child_pid, mold_pid)
        return unless promoting?(child_pid)
        @promotion[:mold_pid] = mold_pid
        promotion_failed(:mold_exited, "Mold (pid #{mold_pid}) exited before it was ready")
      end

      def promoting?(child_pid)
        !@launcher.stopped? && @promotion && @promotion[:pid] == child_pid
      end

      # A mold that isn't the current promotion's: it has forked no child.
      def abandon(mold_pid)
        @molds[mold_pid] = :abandoned
        signal(mold_pid, 'KILL')
      end

      def activate(mold_pid)
        trigger = @promotion[:trigger]
        @promotion = nil
        @threshold_index += 1 if trigger == :threshold
        @hold_until = nil
        @retry_trigger = nil # This mold replaces any lost one.
        retire(@active_mold) if @active_mold
        @molds[mold_pid] = :active
        @active_mold = mold_pid
        @active_since = monotonic_now
        @boot_failures = []
        @generation += 1
        logger.info "Mold (pid #{mold_pid}) ready; reforking child processes from it (generation #{@generation}#{pss_note(@pss_before)})"
        Delayed.instrument(:mold_activated, :pid => mold_pid, :generation => @generation, :pss_mb => @pss_before,
                                            :subreaper => @reaps_orphans)
      end

      def retire(mold_pid)
        @molds[mold_pid] = :retired
        logger.info "Retired mold (pid #{mold_pid}); #{@reaps_orphans ? 'its child processes carry on' : 'it exits once its child processes have'}"
        Delayed.instrument(:mold_retired, :pid => mold_pid)
        signal(mold_pid, 'URG')
      end

      # `reason`: :child_exited (the promoted child forked no mold), :mold_exited
      # (before it was ready) or :timeout.
      def promotion_failed(reason, message)
        promotion = @promotion
        @promotion = nil
        mold = promotion[:mold_pid]
        abandon(mold) if mold && @molds[mold] == :promoted
        return if @launcher.stopped? # Nothing more to promote.
        delay = retry_promotion(promotion[:trigger], message)
        Delayed.instrument(:mold_promotion_failed, :pid => promotion[:pid], :mold_pid => mold, :trigger => promotion[:trigger],
                                                   :reason => reason, :retry_in => delay)
        refill_deferred_slots
      end

      # Back-off doubling per failure in a row. A threshold promotion is
      # retried by the next ping past it; others are retried as such.
      # Returns the delay in seconds.
      # Returns the delay in seconds, or nil once MAX_FAILURES in a row
      # disable promotion.
      def retry_promotion(trigger, message)
        @failures += 1
        return disable(message) if @failures >= MAX_FAILURES
        delay = [retry_delay_unit * 2**(@failures - 1), MAX_RETRY_DELAY].min
        @hold_until = monotonic_now + delay
        @retry_trigger = trigger unless trigger == :threshold
        logger.warn "#{message}; promoting a new mold in #{delay}s"
        delay
      end

      # Each try stops a working child process: stop trying.
      def disable(message)
        @disabled = true
        @retry_trigger = nil
        logger.error "#{message}; #{@failures} mold promotions failed in a row, so no more are tried " \
                     '(child processes are forked from the parent). Send SIGURG to the parent to try again.'
        Delayed.instrument(:mold_disabled, :failures => @failures)
        nil
      end

      def mold_forked_child(mold_pid, pid, index)
        return if @children.key?(pid) || @launcher.workers.key?(pid) # Adopted on its "b".
        entry = @pending_forks.delete(index)
        unless entry
          @early_boots.delete(pid)
          return stop_stray(pid, mold_pid)
        end
        @launcher.child_started(@launcher.child_name(index), pid, entry[:options], entry[:spawn].merge(:mold_pid => mold_pid))
      end

      def mold_fork_failed(mold_pid, index, errno)
        entry = @pending_forks.delete(index)
        return unless entry
        logger.warn "Mold (pid #{mold_pid}) could not fork child process #{index} (errno #{errno}); forking it from the parent"
        error = SystemCallError.new("mold (pid #{mold_pid}) could not fork child process #{index}", errno.to_i)
        Delayed::Worker.thread_error(error, :context => 'Mold forking', :worker => @launcher.child_name(index), :pid => mold_pid)
        count_boot_failure("fork failed (errno #{errno})") # May abort the refork the fork was for.
        start_from_parent(index, entry)
      end

      def mold_reaped_child(mold_pid, pid, exitstatus, termsig)
        info = @children[pid]
        return @early_boots.delete(pid) unless info # Never recorded (e.g. given up on).
        return unless info.mold_pid == mold_pid # Not that mold's (pid reused).
        @launcher.handle_exit(pid, ReportedStatus.new(pid, exitstatus, termsig))
      end

      # Without a subreaper, molds aren't this process's children: poll them.
      def check_molds
        @molds.dup.each_key { |pid| mold_exited(pid) unless ProcessUtil.alive?(pid) }
      end

      def mold_exited(pid)
        @reaped[pid] = monotonic_now
        role = @molds.delete(pid)
        @children.each_value { |info| info.orphaned = true if info.mold_pid == pid } unless @reaps_orphans
        case role
        when :active then lose_active_mold(pid, :exited, 'exited')
        when :promoted then promoted_mold_exited(pid)
        when :retired then logger.info "Retired mold (pid #{pid}) exited"
        end
      end

      def promoted_mold_exited(pid)
        promotion_failed(:mold_exited, "Mold (pid #{pid}) exited before it was ready") if @promotion && @promotion[:mold_pid] == pid
      end

      # Pending forks are forked here, and another promotion replaces it.
      # `reason`: :exited (died, e.g. OOM-killed), :broken or :hung.
      def lose_active_mold(pid, reason, message)
        @active_mold = nil
        abort_refork
        return fork_pending_from_parent if @launcher.stopped?
        logger.warn "Mold (pid #{pid}) #{message}; forking child processes from the parent until a new mold is ready"
        fork_pending_from_parent
        delay = retry_promotion(:mold_lost, "Lost mold (pid #{pid})")
        Delayed.instrument(:mold_lost, :pid => pid, :generation => @generation, :reason => reason, :retry_in => delay)
      end

      def fork_pending_from_parent
        @pipes.drain_fork_requests
        pending = @pending_forks.sort_by(&:first)
        @pending_forks.clear
        pending.each { |index, entry| start_from_parent(index, entry) }
      end

      # Forked from the (cold) parent, it is of no generation: the next
      # refork replaces it from a mold.
      def start_from_parent(index, entry)
        return unless replacement_needed?(entry[:spawn][:replaces_pid])
        @launcher.start_child_safely(index, entry[:options], entry[:spawn].merge(:generation => nil))
      end

      # Old children keep their slots; replacements are dropped or stopped.
      def abort_refork
        @steps.each_key { |old| @children[old]&.retiring = false }
        @pending_forks.delete_if { |_, entry| @steps.key?(entry[:spawn][:replaces_pid]) }
        @steps.each_value do |replacement|
          next unless replacement && @children[replacement]
          @children[replacement].retiring = true # Not replaced.
          signal(replacement, 'TERM')
        end
        @steps.clear
      end

      # A replacement that died before booting: the old child keeps its slot.
      def refork_step_failed(info)
        old = info.replaces
        return false unless old && @steps.delete(old)
        @children[old]&.retiring = false
        logger.warn "Child process replacing pid #{old} died before booting; keeping pid #{old}"
        true
      end

      # How a child failed to boot, for the circuit breaker's message: an
      # error exit (e.g. an after_fork hook raising) points at the app, a
      # boot timeout or signal at the mold (e.g. a lock frozen by fork).
      def boot_failure(pid, info, status)
        return "pid #{pid} boot timeout" if info.boot_timed_out
        status.to_s.start_with?("pid #{pid}") ? status.to_s : "pid #{pid} #{status}"
      end

      # `reason`: how it failed (see #boot_failure).
      def count_boot_failure(reason)
        (@boot_failures ||= []) << reason
        return unless @active_mold && @boot_failures.size >= BOOT_FAILURE_LIMIT
        mold = @active_mold
        logger.error "#{@boot_failures.size} child processes forked by mold (pid #{mold}) failed to start in a row " \
                     "(#{@boot_failures.join(', ')}); stopping it"
        @boot_failures = []
        abandon(mold)
        lose_active_mold(mold, :broken, 'is broken')
      end

      # Without a subreaper, children of a dead mold stop by themselves
      # (Process.ppid changes); the parent can't wait for them, so it polls.
      #
      # With a subreaper, a dead mold's children are this process's: reaped
      # with their real status. Polled too, for one the mold reaped but died
      # before reporting ("x"); an unreaped zombie is left to be reaped.
      def check_orphans
        gone = @children.select { |pid, info| info.mold_pid && !@molds.key?(info.mold_pid) && gone?(pid) }.keys
        gone.each { |pid| @launcher.handle_exit(pid, ReportedStatus.new(pid, nil, nil)) }
      end

      def gone?(pid)
        @reaps_orphans ? !ProcessUtil.exists?(pid) : !ProcessUtil.alive?(pid)
      end

      # Held while a promoted mold isn't activated or abandoned ones may still
      # run (as Puma does): such a mold would read and fork them.
      def send_fork_requests
        return if holding_forks?
        @pending_forks.each do |index, entry|
          next if entry[:sent]
          entry[:sent] = monotonic_now
          @pipes.request_fork(index, Mold.pool_index(@launcher.pools, entry[:options]), entry[:spawn][:generation])
        end
      end

      def holding_forks?
        (@promotion && @promotion[:mold_pid]) || @molds.value?(:abandoned)
      end

      # "s <mold pid>": a mold stopped by a signal sent to it alone forks no
      # more child processes; it is replaced like a lost one.
      def mold_stopping(mold_pid)
        return unless @molds[mold_pid] == :active && !@launcher.stopped?
        retire(mold_pid)
        lose_active_mold(mold_pid, :stopped, 'was stopped by a signal')
      end

      def check_timeouts
        check_pending_forks
        check_boot_timeouts
        check_promotion
        stop_lingering_molds if @launcher.stopped?
        expire_early_boots
        @reaped.delete_if { |_, at| monotonic_now - at > MOLD_READY_TIMEOUT }
        @failures = 0 if @failures > 0 && @active_mold && monotonic_now - @active_since >= MOLD_STABLE_UPTIME
      end

      # A hung mold is killed (it runs no jobs).
      def check_pending_forks
        sent = @pending_forks.values.map { |entry| entry[:sent] }.compact
        return if sent.empty? || !@active_mold
        return if monotonic_now - sent.min < MOLD_FORK_TIMEOUT
        mold = @active_mold
        abandon(mold)
        lose_active_mold(mold, :hung, "did not fork a child process within #{MOLD_FORK_TIMEOUT}s; killed it")
      end

      # A child process that booted but was never reported (e.g. its mold
      # died first, with an old-format "b") is stopped if still running.
      def expire_early_boots
        @early_boots.delete_if do |pid, at|
          next false if monotonic_now - at < boot_timeout
          signal(pid, 'TERM') if ProcessUtil.alive?(pid)
          true
        end
      end

      # Children forked by a mold only: a fork-unsafe mold can deadlock them.
      def check_boot_timeouts
        @children.each do |pid, info|
          next if info.booted || !info.mold_pid || monotonic_now - info.started_at < boot_timeout
          logger.warn "Child process (pid #{pid}) did not start within #{boot_timeout}s; killing it"
          info.started_at = monotonic_now # Killed once.
          info.boot_timed_out = true
          signal(pid, 'KILL')
        end
      end

      def check_promotion
        return unless @promotion
        return refill_draining_slot if draining_too_long?
        return unless promotion_overdue?
        promotion_failed(:timeout, "Child process (pid #{@promotion[:pid]}) promoted to mold, but no mold became ready")
      end

      def draining_too_long?
        info = @children[@promotion[:pid]]
        info && !info.retiring && monotonic_now - @promotion[:at] >= drain_deadline
      end

      def promotion_overdue?
        exited_at = @promotion[:exited_at]
        return false unless exited_at
        waited = monotonic_now - exited_at
        waited >= MOLD_READY_TIMEOUT || (waited >= PROMOTION_FORK_TIMEOUT && !@promotion[:mold_pid])
      end

      # A promoted child stuck behind a long job: its slot is refilled now,
      # so it counts as retiring.
      def refill_draining_slot
        pid = @promotion[:pid]
        @children[pid].retiring = true
        _, options = @launcher.workers[pid]
        logger.warn "Child process (pid #{pid}) promoted to mold is still finishing its jobs after #{drain_deadline}s; refilling its slot"
        @launcher.add_worker_safely(options, pid) if options
      end

      # A stopping mold forks nothing more, and is killed if it hangs.
      def stop_lingering_molds
        unless @pending_forks.empty?
          @pipes.drain_fork_requests
          @pending_forks.clear
        end
        return @children_gone_at = nil unless @launcher.workers.empty? && @molds.any?
        @children_gone_at ||= monotonic_now
        return if monotonic_now - @children_gone_at < MOLD_STOP_TIMEOUT
        logger.warn "Killing mold(s) still running #{MOLD_STOP_TIMEOUT}s after the child processes stopped: #{@molds.keys.join(', ')}"
        signal_molds('KILL')
        @children_gone_at = monotonic_now # Then again if still not gone.
      end

      # Up to REFORK_SHARE of the child processes at once, idle ones first:
      # each replacement is forked from the active mold, and the child it
      # replaces is stopped once it boots (see #mark_booted).
      def advance_refork
        return if @launcher.stopped? || @promotion || !@active_mold
        refill_deferred_slots
        start_refork_steps
        refork_completed if @refork_generation != @generation && refork_idle?
      end

      def start_refork_steps
        while @steps.size < refork_batch && (old_pid = next_to_refork)
          refork(old_pid)
        end
      end

      def refork_batch
        [(@children.size * REFORK_SHARE).ceil, 1].max
      end

      # A child process not of the current generation, not already handled:
      # idle first, then cold ones (forked by the parent) and the oldest.
      def next_to_refork
        @children.select { |_, info| reforkable?(info) }.min_by { |_, info| [info.busy, info.generation || -1] }&.first
      end

      def reforkable?(info)
        info.booted && !current?(info) && !info.retiring && !info.promoted
      end

      def refork(old_pid)
        worker_name, options = @launcher.workers[old_pid]
        return unless options
        @children[old_pid].retiring = true
        @steps[old_pid] = nil
        logger.info "Reforking child process #{worker_name} (pid #{old_pid}) from mold (pid #{@active_mold})"
        @launcher.add_worker_safely(options, old_pid)
      end

      def refork_completed
        @refork_generation = @generation
        pss = total_pss_mb
        logger.info "Reforked every child process from mold (pid #{@active_mold}), generation #{@generation}#{pss_note(pss, @pss_before)}"
        Delayed.instrument(:mold_refork_completed, :pid => @active_mold, :generation => @generation, :pss_mb => pss, :pss_mb_before => @pss_before)
      end

      def refill_deferred_slots
        until @deferred_slots.empty? || @launcher.stopping?
          options, replaces_pid = @deferred_slots.shift
          @launcher.add_worker_safely(options, replaces_pid)
        end
      end

      # Total PSS of the child processes and molds, in MB (Linux), or nil.
      def total_pss_mb
        sizes = (@launcher.workers.keys + @molds.keys).map { |pid| ProcessUtil.pss_kb(pid) }.compact
        (sizes.sum / 1024.0).round if sizes.any?
      end

      def pss_note(pss, before = nil)
        return '' unless pss
        before ? "; PSS #{before} MB -> #{pss} MB" : "; PSS #{pss} MB"
      end

      def signal(pid, signal)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
