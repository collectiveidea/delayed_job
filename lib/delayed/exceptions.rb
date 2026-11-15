require 'timeout'

module Delayed
  class WorkerTimeout < Timeout::Error
    def message
      seconds = Delayed::Worker.max_run_time.to_i
      "#{super} (Delayed::Worker.max_run_time is only #{seconds} second#{seconds == 1 ? '' : 's'})"
    end
  end

  class FatalBackendError < RuntimeError; end

  # Raised into a job's thread on SIGQUIT or when shutdown_timeout expires;
  # the job is released with attempts unchanged. Not a StandardError, so
  # `rescue => e` in job code doesn't swallow it.
  class ShutdownInterrupt < Exception # rubocop:disable Lint/InheritException
  end

  # The pidfile belongs to a running process.
  class AlreadyRunningError < StandardError
    attr_reader :path, :pid

    def initialize(path, pid)
      @path = path
      @pid = pid
      running = pid ? " (pid #{pid})" : ''
      super("delayed_job is already running#{running}: pidfile #{path} exists. " \
            'Stop that process, or delete the file if it is not a delayed_job process.')
    end
  end

  # Recorded on jobs that were running in a child process when it died.
  class ProcessExitError < StandardError
    attr_reader :worker_name, :pid, :status

    def initialize(worker_name, pid, status)
      @worker_name = worker_name
      @pid = pid
      @status = status
      super("Child process #{worker_name} (pid #{pid}) #{exit_reason(status)}")
      set_backtrace([])
    end

  private

    def exit_reason(status)
      return "was killed by signal #{status.termsig}" if status.signaled?
      return "exited with status #{status.exitstatus}" if status.exitstatus
      'exited (status unknown: its mold died first)'
    end
  end
end
