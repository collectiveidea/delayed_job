require 'fileutils'

module Delayed
  # Forking launcher pidfile. Liveness is an flock, not the pid: the OS
  # releases it however the process dies (even SIGKILL), so stale files and
  # recycled pids are harmless. Workers inherit the lock, so it's held until
  # all of them exit too.
  class Pidfile
    attr_reader :path

    # Worker.after_fork must not reopen this file: that would drop the lock.
    def self.lock_file?(file)
      file.instance_variable_defined?(:@delayed_pidfile)
    end

    def initialize(path)
      @path = path.to_s
    end

    # Raises Delayed::AlreadyRunningError if another process holds the lock.
    def setup
      FileUtils.mkdir_p(File.dirname(path))
      @file = lock_file
      @file.truncate(0)
      @file.write("#{Process.pid}\n")
      @file.flush
      self
    end

    # No-op in forked children; never deletes a newer launcher's file.
    def delete
      return unless @file && @owner == Process.pid
      File.delete(path) if same_file?(@file)
      @file.close
      @file = nil
    rescue Errno::ENOENT
      nil
    end

    # nil if missing or not a pid.
    def read_pid
      pid = File.read(path).strip
      Integer(pid, 10) if pid =~ /\A\d+\z/
    rescue Errno::ENOENT
      nil
    end

  private

    def lock_file
      loop do
        file = File.open(path, File::RDWR | File::CREAT, 0o644)
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          file.close
          raise AlreadyRunningError.new(path, read_pid)
        end
        # The previous holder may have deleted the file between our open and
        # lock, leaving us an orphan: retry.
        if same_file?(file)
          file.instance_variable_set(:@delayed_pidfile, true)
          @owner = Process.pid
          return file
        end
        file.close
      end
    end

    # By dev/inode: File.identical?(path, io) compares paths on JRuby.
    def same_file?(file)
      on_disk = File.stat(path)
      open = file.stat
      on_disk.dev == open.dev && on_disk.ino == open.ino
    rescue Errno::ENOENT
      false
    end
  end
end
