module Delayed
  module Launcher
    # Mold process (experimental); see Delayed::Worker.mold, and
    # MoldSupervisor for the parent side.
    #
    # A promoted child process stops like on TERM, forks a mold and exits.
    # The mold runs no jobs: it forks the child processes the parent asks
    # for, which share its warmed memory copy-on-write, and reports their
    # exits. When the parent is a child subreaper (Linux), the mold is
    # reparented to it at once, and so are its children if it exits.
    class Mold
      FORK_RECORD = 'NNN'.freeze # worker index, pool index, generation
      FORK_RECORD_BYTES = 12
      NO_POOL = 0xFFFF_FFFF

      # Exit status of a promoted child process that forks no mold (its
      # promotion was cancelled by a signal, or its threads didn't stop).
      PROMOTION_FAILED = 75

      # Index of the pool with these options' queues, or NO_POOL.
      def self.pool_index(pools, options)
        return NO_POOL unless pools
        pools.index { |queues, _| queues == options[:queues] } || NO_POOL
      end

      # Pipes opened by the parent before its first fork, inherited by every
      # child process and mold:
      # * fork: the parent writes FORK_RECORDs; only the active mold reads.
      # * status: one line per message, shorter than PIPE_BUF so writes from
      #   several processes don't interleave:
      #     b <pid>                             child booted
      #     p <pid> <jobs> <busy> <unsafe>      child ping
      #     M <child pid> <mold pid>            promoted child forked its mold
      #     m <mold pid> <child pid>            mold ready
      #     f <mold pid> <pid> <idx>            mold forked a child
      #     e <mold pid> <idx> <errno>          mold failed to fork a child
      #     x <mold pid> <pid> <exit> <signal>  mold reaped a child ("-": nil)
      # * life: never written; EOF tells a mold the parent is gone.
      class Pipes
        attr_reader :fork_read, :life_read

        def initialize
          @fork_read, @fork_write = IO.pipe
          @status_read, @status_write = IO.pipe
          @life_read, @life_write = IO.pipe
          @fork_write.sync = true
          @status_write.sync = true
          @status_buffer = +''
        end

        # In a child process. Idempotent.
        def close_parent_ends
          [@fork_write, @status_read, @life_write].each(&:close)
        end

        # Lines are written whole (sync). A ping is dropped rather than block
        # when the parent falls behind.
        def report(line, blocking: true)
          line = "#{line}\n"
          blocking ? @status_write.write(line) : @status_write.write_nonblock(line, :exception => false)
        rescue IOError, SystemCallError
          nil # The parent is gone.
        end

        def request_fork(worker_index, pool_index, generation)
          @fork_write.write([worker_index, pool_index, generation].pack(FORK_RECORD))
        end

        # [worker index, pool index, generation], nil if none, or :eof once
        # the parent is gone.
        def read_fork_request
          record = @fork_read.read_nonblock(FORK_RECORD_BYTES, :exception => false)
          return :eof if record.nil?
          record.unpack(FORK_RECORD) if record.is_a?(String) && record.bytesize == FORK_RECORD_BYTES
        end

        def drain_fork_requests
          loop { break unless @fork_read.read_nonblock(4096, :exception => false).is_a?(String) }
        end

        # Yields each status line received within `timeout` seconds, as its
        # type and integer arguments (nil for "-").
        def each_status(timeout)
          return unless @status_read.wait_readable(timeout)
          @status_buffer << @status_read.read_nonblock(65_536)
          while (line = @status_buffer.slice!(/\A[^\n]*\n/))
            type, *args = line.split
            yield type, *args.map { |arg| arg == '-' ? nil : arg.to_i }
          end
        rescue IO::WaitReadable
          nil
        end
      end

      # `info`: :promoted_pid (the child that forked it), :generation, and
      # :exit_when_retired (true when the parent adopts its children).
      def initialize(launcher, pipes, info)
        @launcher = launcher
        @pipes = pipes
        @info = info
        @children = {}
        @retired = false
        @stopping = false
      end

      # Yields once the signal traps are in place (to name the process).
      # Returns when retired (at once if the parent adopts its children, else
      # once they have exited), or when stopping and its children have
      # exited. Exits (status 1) as soon as the parent is gone.
      def run
        @wake_read, @wake_write = IO.pipe
        trap_signals
        return if @launcher.child_signals.any? # Signalled before the traps.
        yield if block_given?
        watch_parent
        Delayed::Worker.lifecycle.run_callbacks(:mold, Process.pid, @info[:generation]) do
          @launcher.warmup_heap # After the hooks, which may free memory.
          warn_about_threads
          @pipes.report("m #{Process.pid} #{@info[:promoted_pid]}")
          fork_loop
        end
      end

    private

      # Traps only write to the wake pipe: C child exited, U retired (stop
      # forking), S stop (stop forking, exit once the children have). In a
      # child, before it replaces them, they record the signal (see
      # Forking#capture_signals).
      def trap_signals
        mold_pid = Process.pid
        {'CHLD' => 'C', 'URG' => 'U', 'TERM' => 'S', 'INT' => 'S', 'QUIT' => 'S'}.each do |signal, code|
          Signal.trap(signal) do
            if Process.pid == mold_pid
              @wake_write.write_nonblock(code, :exception => false)
            elsif code == 'S'
              @launcher.child_signal(signal)
            end
          end
        end
        Signal.trap('HUP') {} # rubocop:disable Lint/EmptyBlock
      end

      # Exits at once when the parent is gone (as Puma's workers do), whatever
      # the mold is doing, e.g. a hung :mold hook: left running, it would
      # keep the pidfile locked. Its children then stop by themselves. Only
      # the forking thread is in a fork, so they don't have this one.
      def watch_parent
        watchdog = Thread.new do
          @pipes.life_read.wait_readable
          parent_gone
        end
        watchdog.name = 'Mold parent watchdog'
        watchdog.thread_variable_set(:fork_safe, true) # Here: before #warn_about_threads looks.
      end

      def parent_gone
        @launcher.logger.warn "Mold (pid #{Process.pid}): the parent is gone; exiting"
        @launcher.flush_and_exit!(1)
      end

      # Threads don't survive fork: whatever they were doing is frozen,
      # mid-way, in every child forked from here.
      def warn_about_threads
        others = Thread.list.reject { |thread| thread == Thread.current || !thread.alive? || fork_safe_thread?(thread) }
        return if others.empty?
        names = others.map { |thread| thread_label(thread) }.join(', ')
        @launcher.logger.warn "Mold (pid #{Process.pid}) has #{others.size} other thread(s) running, which child processes " \
                              "won't have: #{names}. See Fork safety in the README."
      end

      # Marked fork safe (as Puma honours, e.g. Active Record's pool reaper),
      # or known to handle fork itself.
      FORK_SAFE_THREAD_NAMES = ['Timeout stdlib thread'].freeze

      def thread_label(thread)
        "#{thread.name || thread.inspect} (at #{thread.backtrace&.first})"
      end

      def fork_safe_thread?(thread)
        thread.thread_variable_get(:fork_safe) || FORK_SAFE_THREAD_NAMES.include?(thread.name)
      end

      def fork_loop
        loop do
          ready = wait_for_work
          reap_children
          fork_requested_child if ready.include?(@pipes.fork_read) && !done?
          return if finished?
        end
      end

      # Adopted by the parent, its children don't need it once retired.
      def finished?
        (@retired && @info[:exit_when_retired]) || (done? && @children.empty?)
      end

      def done?
        @retired || @stopping
      end

      # Returns the readable pipes; wakes at least every second.
      def wait_for_work
        readers = [@wake_read]
        readers << @pipes.fork_read unless done?
        ready = IO.select(readers, nil, nil, 1)&.first || []
        read_wakeups
        ready
      end

      def read_wakeups
        codes = @wake_read.read_nonblock(64, :exception => false)
        return unless codes.is_a?(String)
        @retired ||= codes.include?('U')
        return unless codes.include?('S') && !@stopping
        @stopping = true
        report_stopping
      end

      # So the parent replaces it at once if it alone was signalled.
      def report_stopping
        @pipes.report("s #{Process.pid}") unless @retired
      end

      # A failed fork (EAGAIN, ENOMEM) is reported; the parent forks the
      # child itself.
      def fork_requested_child
        request = @pipes.read_fork_request
        parent_gone if request == :eof # Rather than spin on it until the watchdog exits.
        worker_index, pool_index, generation = request
        return unless worker_index
        disconnect_backend
        pid = @launcher.fork_mold_child(worker_index, pool_index, generation, [@wake_read, @wake_write])
        @children[pid] = true
        @pipes.report("f #{Process.pid} #{pid} #{worker_index}")
      rescue SystemCallError => error
        @launcher.logger.error "Mold (pid #{Process.pid}) could not fork child process #{worker_index}: #{error.class}: #{error.message}"
        @pipes.report("e #{Process.pid} #{worker_index} #{error.errno}")
      end

      # Connections opened in the mold (e.g. by a :mold hook) must not be
      # shared with its children.
      def disconnect_backend
        Delayed::Worker.backend.before_fork
      rescue StandardError => error
        @launcher.logger.error "Mold (pid #{Process.pid}) could not disconnect from the database: #{error.class}: #{error.message}"
      end

      # Only its own children: a hook's subprocesses are the hook's to reap.
      def reap_children
        @children.dup.each_key do |pid|
          _, status = Process.wait2(pid, Process::WNOHANG)
          next unless status
          @children.delete(pid)
          @pipes.report("x #{Process.pid} #{pid} #{status.exitstatus || '-'} #{status.termsig || '-'}")
        rescue Errno::ECHILD
          @children.delete(pid)
        end
      end
    end
  end
end
