# frozen_string_literal: true

require 'delayed/launcher/runner'
require 'delayed/launcher/child_handle'
require 'delayed/launcher/child'

module Delayed
  module Launcher

    # This class is instantiated by `Delayed::Launcher` and used
    # to boot and run a Delayed Job application using multiple child
    # worker processes. For example: `$ delayed_job -n5`
    #
    # An instance of this class will spawn the number of processes passed in
    # via the `spawn_childs` method call. Each child will have it's own
    # instance of a `Delayed::Worker`.
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Cluster`
    class Cluster < Runner
      attr_accessor :child_count

      # DEFAULT_FORK_WORKER_JOBS = 1000

      def initialize(launcher, options)
        check_fork_supported!

        @started_at = Time.now
        @child_handles = []
        @child_index = 0
        @child_count = options.delete(:worker_count) || raise(':worker_count required')
        @next_check = Time.now
        @phase = 0
        @phased_restart = false
        @last_phased_restart = @started_at

        super
      end

      # TODO: NOT NEEDED
      # def restart
      #   @restart = true
      #   stop
      #   # TODO: parent needs to restart
      # end

      def phased_restart
        @phased_restart = true
        wakeup!
      end

      def stop
        @status = :stop
        wakeup!
      end

      def halt
        @status = :halt
        wakeup!
      end

      def run
        @status = :run

        output_header(mode)

        # This is aligned with Runner#output_header
        logger.info "*      Workers: #{@child_count}"
        # logger.info "*     Restarts: (\u2714) hot (\u2714) phased"

        setup_pipes
        setup_signals
        setup_auto_fork_once
        spawn_childs
        run_loop
      end

    private

      def mode
        'cluster'
      end

      def run_loop
        booted = false
        in_phased_restart = false
        childs_not_booted = @child_count

        while @status == :run
          begin
            if @phased_restart
              start_phased_restart
              @phased_restart = false
              in_phased_restart = true
              childs_not_booted = @child_count
            end

            check_childs

            if @parent_read.wait_readable([0, @next_check - Time.now].max)
              req = @parent_read.read_nonblock(1)

              @next_check = Time.now if req == '!'
              next if !req || req == '!'

              result = @parent_read.gets
              pid = result.to_i

              if req == 'b' || req == 'f'
                pid, idx = result.split(':').map(&:to_i)
                handle = @child_handles.find { |h| h.index == idx }
                handle.pid = pid if handle.pid.nil?
              end

              if handle = @child_handles.find { |h| h.pid == pid }
                case req
                when 'b'
                  handle.boot!
                  logger.info "- Worker #{handle.index} (PID: #{pid}) booted in #{handle.uptime.round(2)}s, phase: #{handle.phase}"
                  @next_check = Time.now
                  childs_not_booted -= 1
                when 'e'
                  # external term, see child method, Signal.trap "SIGTERM"
                  handle.term!
                when 't'
                  handle.term unless handle.term?
                when 'p'
                  handle.ping!
                  events.fire(:ping, handle)
                  if !booted && @child_handles.all? { |h| h.last_status == :ok }
                    events.fire(:on_booted)
                    booted = true
                  end
                end
              else
                logger.info "! Out-of-sync child list, no #{pid} child"
              end
            end

            if in_phased_restart && childs_not_booted.zero?
              events.fire(:on_booted)
              in_phased_restart = false
            end

          rescue Interrupt
            @status = :stop
          end
        end

        stop_childs unless @status == :halt
      ensure
        @check_pipe.close
        @suicide_pipe.close
        @parent_read.close
        @wakeup.close
      end

      def start_phased_restart
        events.fire(:on_restart)
        @phase += 1
        @last_phased_restart = Time.now
        logger.info "- Starting phased worker restart, phase: #{@phase}"

        # Be sure to change the directory again before loading
        # the app. This way we can pick up new code.
        dir = Delayed.root # @launcher.restart_dir
        logger.info "+ Changing to #{dir}"
        Dir.chdir dir
      end

      def stop_childs
        logger.info '- Gracefully shutting down workers...'
        @child_handles.each(&:term)

        begin
          loop do
            wait_childs
            break if @child_handles.reject { |h| h.pid.nil? }.empty?
            sleep 0.2
          end
        rescue Interrupt
          logger.warn '! Cancelled waiting for workers'
        end
      end

      def wakeup!
        return if !@wakeup || @wakeup.closed?
        @wakeup.write('!')
      rescue SystemCallError, IOError
        Delayed.purge_interrupt_queue
      end

      def fork_child_zero!
        if (handle = @child_handles.find { |h| h.index == 0 })
          handle.phase += 1
        end
        phased_restart
      end

      def setup_pipes
        @parent_read, @child_write = IO.pipe
        @wakeup = @child_write

        # Used by the childs to detect if the parent process dies.
        # If select says that @check_pipe is ready, it's because the
        # parent has exited and @suicide_pipe has been automatically closed.
        @check_pipe, @suicide_pipe = IO.pipe

        # Separate pipe used by child 0 to receive commands to
        # fork new child processes.
        @fork_pipe, @fork_writer = IO.pipe
      end

      def setup_signals
        setup_signal_shutdown('SIGINT')
        setup_signal_shutdown('SIGTERM')
        setup_signal_wakeup
        setup_signal_increment
        setup_signal_decrement
        setup_signal_fork_child_zero
        logger.info 'Use Ctrl-C to stop'
      end

      def setup_signal_wakeup
        Signal.trap('SIGCHLD') { wakeup! }
      end

      def setup_signal_increment
        Signal.trap('TTIN') do
          increment_child_count
          wakeup!
        end
      end

      def setup_signal_decrement
        Signal.trap('TTOU') do
          decrement_child_count
          wakeup!
        end
      end

      def setup_signal_fork_child_zero
        Signal.trap('SIGURG') { fork_child_zero! }
      end

      # Trapped signals are forwarded child processes.
      # Hence it is not necessary to explicitly shutdown childs;
      # we only need to stop the run loop.
      def setup_signal_shutdown(signal)
        parent_pid = Process.pid

        Signal.trap(signal) do
          # The child installs their own SIGTERM when booted.
          # Until then, this is run by the child and the child
          # should just exit if they get it.
          if Process.pid != parent_pid
            logger.info 'Early termination of worker'
            exit! 0
          else
            stop_childs
            stop
            events.fire(:on_stopped)
            raise(SignalException, signal) if (signal == 'SIGTERM' ? raise_sigterm : raise_sigint)
            exit 0 # Clean exit, childs were stopped
          end
        end
      end

      def increment_child_count
        @child_count += 1
      end

      def decrement_child_count
        @child_count -= 1 if @child_count >= 2
      end

      def setup_auto_fork_once
        refork_delay = @options[:worker_refork_delay]
        return unless refork_delay
        events.register(:ping) do |handle|
          break unless handle.index == 0 && handle.phase == 0
          time_exceeded = refork_delay && Time.now > @last_phased_restart + refork_delay
          break unless time_exceeded
          fork_child_zero!
        end
      end

      def all_childs_booted?
        @child_handles.count { |h| !h.booted? } == 0
      end

      def check_childs
        return if @next_check >= Time.now

        @next_check = Time.now + @options[:worker_check_interval]

        timeout_childs
        wait_childs
        cull_childs
        spawn_childs
        phase_out_childs

        @next_check = [
          @child_handles.reject(&:term?).map(&:ping_timeout).min,
          @next_check
        ].compact.min
      end

      def timeout_childs
        @child_handles.each do |handle|
          next unless !handle.term? && handle.ping_timeout <= Time.now
          details = if handle.booted?
                      "(worker failed to check in within #{@options[:worker_timeout]} seconds)"
                    else
                      "(worker failed to boot within #{@options[:worker_boot_timeout]} seconds)"
                    end
          logger.info "! Terminating timed out worker #{details}: #{handle.pid}"
          handle.kill
        end
      end

      # loops thru @child_handles, removing childs that exited,
      # and calling `#term` if needed
      def wait_childs
        @child_handles.reject! do |handle|
          begin
            next false if handle.pid.nil?
            if Process.wait(handle.pid, Process::WNOHANG)
              true
            else
              handle.term if handle.term?
              nil
            end
          rescue Errno::ECHILD
            begin
              Process.kill(0, handle.pid)
              # child still alive but has another parent (e.g., using fork_child)
              handle.term if handle.term?
              false
            rescue Errno::ESRCH, Errno::EPERM
              true # child is already terminated
            end
          end
        end
      end

      def cull_childs
        diff = @child_handles.size - @child_count
        return if diff < 1

        logger.debug "Culling #{diff.inspect} workers"

        handles_to_cull =
          case @options[:worker_culling_strategy]
          when :youngest
            @child_handles.sort_by(&:started_at)[-diff, diff]
          when :oldest
            @child_handles.sort_by(&:started_at)[0, diff]
          end
        logger.debug "Workers to cull: #{handles_to_cull.inspect}"

        handles_to_cull.each do |handle|
          logger.info "- Worker #{handle.index} (PID: #{handle.pid}) terminating"
          handle.term
        end
      end

      def spawn_childs
        diff = @child_count - @child_handles.size
        return if diff < 1

        parent = Process.pid
        @fork_writer << "-1\n"

        diff.times do
          idx = next_child_index

          if idx != 0
            @fork_writer << "#{idx}\n"
            pid = nil
          else
            pid = spawn_child(idx, parent)
          end

          logger.debug "Spawned worker: #{pid}"
          @child_handles << ChildHandle.new(idx, pid, @phase, @options)
        end

        if @child_handles.all? { |h| h.phase == @phase }
          @fork_writer << "0\n"
        end
      end

      def next_child_index
        occupied_positions = @child_handles.map(&:index)
        idx = 0
        idx += 1 until !occupied_positions.include?(idx)
        idx
      end

      def spawn_child(idx, parent)
        Delayed::Worker.before_fork

        pid = fork { create_child(idx, parent) }
        unless pid
          logger.info '! Complete inability to spawn new child processses detected'
          logger.info '! Seppuku is the only choice.'
          exit! 1
        end

        Delayed::Worker.after_fork
        pid
      end

      def create_child(index, parent)
        @child_handles = []

        @parent_read.close
        @suicide_pipe.close
        @fork_writer.close

        pipes = { check_pipe: @check_pipe,
                  child_write: @child_write,
                  fork_pipe: @fork_pipe,
                  wakeup: @wakeup }

        new_child = Child.new(index,
                              parent,
                              logger,
                              @options,
                              pipes,
                              nil)
        new_child.run
      end

      # If we're running at proper capacity, check to see if
      # we need to phase any childs out (which will restart
      # in the right phase).
      def phase_out_childs
        return unless all_childs_booted?

        handle = @child_handles.find { |h| h.phase != @phase }
        return unless handle

        logger.info "- Stopping #{handle.pid} for phased upgrade..."

        return if handle.term?
        handle.term
        logger.info "- #{handle.signal} sent to #{handle.pid}..."
      end
    end
  end
end


# OLD
# def run
#   @stopped = !!@options[:exit_on_complete]
#   @killed = false
#   setup_logger
#   setup_signals
#   setup_auto_fork_worker
#   Delayed::Worker.before_fork if worker_count > 1
#   setup_workers
#   run_loop if worker_count > 1
#   before_graceful_exit
# end


# OLD
# def stop(timeout = nil)
#   @stopped = true
#   message = " with #{timeout} second grace period" if timeout
#   logger.info "Shutdown invoked#{message}"
#   @child_handles.reject(&:term?).each do |worker|
#     logger.info "Sending SIGTERM to worker #{worker.name}"
#     worker.term
#   end
#   schedule_kill(timeout) if timeout
# end
#
# OLD
# def halt(exit_status = 0, message = nil)
#   @stopped = true
#   @killed = true
#   message = " #{message}" if message
#   logger.warn "Kill invoked#{message}"
#   @child_handles.each do |worker|
#     logger.info "Sending SIGKILL to worker #{worker.name}"
#     worker.kill
#   end
#   logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
#   exit(exit_status)
# end

# def before_graceful_exit
#   logger.info "#{parent_name} exited gracefully - pid #{$$}"
# end
#
# def parent_name
#   "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1}"
# end


# TODO: is this needed?
# def stop_blocked
#   @status = :stop if @status == :run
#   wakeup!
#   Process.waitall
# end

# def reload_worker_directory
#   dir = @launcher.restart_dir
#   logger.info "+ Changing to #{dir}"
#   Dir.chdir dir
# end

# Inside of a child process, this will return all zeroes, as @child_handles is only populated in
# the parent process.
# @!attribute [r] stats
# def stats
#   old_worker_count = @child_handles.count { |handle| handle.phase != @phase }
#   worker_status = @child_handles.map do |handle|
#     {
#       started_at: handle.started_at.utc.iso8601,
#       pid: handle.pid,
#       index: handle.index,
#       phase: handle.phase,
#       booted: handle.booted?,
#       last_checkin: handle.last_checkin.utc.iso8601,
#       last_status: handle.last_status,
#     }
#   end
#
#   {
#     started_at: @started_at.utc.iso8601,
#     workers: @child_handles.size,
#     phase: @phase,
#     booted_workers: worker_status.count { |handle| w[:booted] },
#     old_workers: old_worker_count,
#     worker_status: worker_status,
#   }
# end



# OLD
# def add_worker(options)
#   worker_name = get_name(@worker_index)
#   worker_pid = spawn_worker(worker_name, options)
#
#   queues = options[:queues]
#   queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
#   logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"
#
#   @child_handles << ChildHandle.new(@worker_index, worker_pid, worker_name, queues)
#   @worker_index += 1
# end
#
# OLD
# def run_worker(worker_name, options)
#   Dir.chdir(Delayed.root)
#   set_process_name(worker_name)
#   Delayed::Worker.after_fork
#   setup_logger
#   worker = Delayed::Worker.new(options)
#   worker.name_prefix = "#{worker_name} "
#   worker.start
# rescue => e
#   STDERR.puts e.message
#   STDERR.puts e.backtrace
#   logger.fatal(e)
#   exit_with_error_status
# end
#
#
# def exit_with_error_status
#   exit(1)
# end
