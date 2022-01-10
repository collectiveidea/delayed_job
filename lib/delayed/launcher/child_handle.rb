# frozen_string_literal: true

module Delayed
  module Launcher

    # This class represents a child worker process from the perspective of the
    # Delayed Job parent process. It contains information about the process and
    # its health, and it exposes methods to control the process via IPC. It does not
    # include the actual logic executed by the child worker process itself.
    # For that, see `Delayed::Launcher::Child`.
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Cluster::WorkerHandle`
    class ChildHandle
      def initialize(idx, pid, phase, options)
        @index = idx
        @pid = pid
        @phase = phase
        @stage = :started
        @signal = 'TERM'
        @options = options
        @first_term_sent = nil
        @started_at = Time.now
        @last_checkin = Time.now
        @last_status = nil
        @term = false
      end

      attr_accessor :pid,
                    :phase

      attr_reader :index,
                  :signal,
                  :last_checkin,
                  :last_status,
                  :started_at

      def booted?
        @stage == :booted
      end

      def uptime
        Time.now - started_at
      end

      def boot!
        @last_checkin = Time.now
        @stage = :booted
      end

      def term!
        @term = true
      end

      def term?
        @term
      end

      def ping!
        @last_checkin = Time.now
        @last_status = :ok
      end

      # @see Cluster#check_workers
      def ping_timeout
        @last_checkin + (booted? ? @options[:worker_timeout] : @options[:worker_boot_timeout])
      end

      def term
        begin
          if @first_term_sent && (Time.now - @first_term_sent) > @options[:worker_shutdown_timeout]
            @signal = 'KILL'
          else
            @term ||= true
            @first_term_sent ||= Time.now
          end
          Process.kill @signal, @pid if @pid
        rescue Errno::ESRCH
        end
      end

      def kill
        @signal = 'KILL'
        term
      end

      def hup
        Process.kill 'HUP', @pid
      rescue Errno::ESRCH
      end
    end
  end
end
