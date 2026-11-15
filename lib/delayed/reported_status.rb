module Delayed
  # The exit status of a child process that the launcher couldn't wait for (a
  # mold forked it), as reported by its mold. Quacks like Process::Status.
  # Both exitstatus and termsig are nil when unknown (its mold died first).
  class ReportedStatus
    attr_reader :pid, :exitstatus, :termsig

    def initialize(pid, exitstatus, termsig)
      @pid = pid
      @exitstatus = exitstatus
      @termsig = termsig
    end

    def success?
      exitstatus == 0
    end

    def signaled?
      !termsig.nil?
    end

    def exited?
      !exitstatus.nil?
    end

    def known?
      exited? || signaled?
    end

    def to_s
      return "pid #{pid} SIG#{Signal.signame(termsig)} (signal #{termsig})" if signaled?
      return "pid #{pid} exit #{exitstatus}" if exited?
      "pid #{pid} exit unknown"
    end
    alias_method :inspect, :to_s
  end
end
