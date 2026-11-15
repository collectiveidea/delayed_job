module Delayed
  # Process helpers for the mold process (Linux; safe no-ops elsewhere).
  module ProcessUtil
  module_function

    # Makes orphaned descendants reparent to this process instead of init,
    # so it can wait for them. Returns whether it worked: Linux, with the C
    # extension (ext/delayed_job) built; not on JRuby.
    def enable_child_subreaper
      require 'delayed/subreaper'
      native_enable_child_subreaper
    rescue LoadError
      false
    end

    # Whether this process's parent is still `supervisor` (a pid, or any of
    # several pids): once it dies, the process is reparented.
    def parent_alive?(supervisor)
      Array(supervisor).include?(Process.ppid)
    end

    # Whether `pid` still runs: false once it exited, even as an unreaped
    # zombie, or if the pid now belongs to another user (EPERM).
    def alive?(pid)
      Process.kill(0, pid)
      !zombie?(pid)
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Whether the pid exists at all (a zombie does).
    def exists?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def zombie?(pid)
      stat = File.read("/proc/#{pid}/stat")
      stat[stat.rindex(')') + 2] == 'Z' # The state follows "(comm) ".
    rescue SystemCallError, IOError
      false
    end

    # Proportional set size of `pid` in kB (Linux), or nil.
    def pss_kb(pid)
      File.foreach("/proc/#{pid}/smaps_rollup") { |line| return line.split[1].to_i if line.start_with?('Pss:') }
      nil
    rescue SystemCallError, IOError
      nil
    end
  end
end
