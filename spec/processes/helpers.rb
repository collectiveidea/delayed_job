require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative 'backend'
require_relative 'jobs'

# Helpers for specs that run a real forking launcher in a subprocess, on an
# SQLite file database shared with the spec process.
module ProcessHelpers
  LAUNCH_SCRIPT = File.expand_path('launch.rb', __dir__)
  LIB_DIR = File.expand_path('../../lib', __dir__)

  Job = Delayed::Backend::SqliteFile::Job
  Run = Delayed::Backend::SqliteFile::Run

  def self.included(base)
    base.around do |example|
      Dir.mktmpdir('dj-processes') do |dir|
        @process_db = File.join(dir, 'jobs.sqlite3')
        Job.connect(@process_db)
        Job.create_schema
        example.run
      ensure
        kill_launchers
      end
    end
  end

  # Enqueues a job directly in the SQLite database.
  def enqueue_process_job(payload, attributes = {})
    Job.create!({:handler => payload.to_yaml, :run_at => Job.db_time_now}.merge(attributes))
  end

  # Starts the launcher in a subprocess, in its own process group; returns
  # [pid, output_reader].
  def spawn_launcher(options = {})
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, '-I', LIB_DIR, LAUNCH_SCRIPT, @process_db, JSON.generate(options),
                        :out => writer, :err => writer, :pgroup => true)
    writer.close
    launchers << pid
    [pid, reader]
  end

  # Launchers still running after the example (it failed before stopping
  # one): kill each one's process group, so none outlives it, holding jobs
  # or a child the next examples would wait for.
  def kill_launchers
    launchers.each do |pid|
      Process.kill('KILL', -pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  def launchers
    @launchers ||= []
  end

  # Runs the launcher until it exits; returns [Process::Status, output].
  def run_launcher(options = {}, timeout = 30)
    pid, reader = spawn_launcher(options)
    wait_for_launcher(pid, reader, timeout)
  end

  # Collects the launcher's output until it exits; returns [Process::Status, output].
  # Kills its whole process group if it runs longer than `timeout` seconds.
  def wait_for_launcher(pid, reader, timeout = 30)
    output = +''
    deadline = Time.now + timeout
    status = nil
    until status
      output << read_available(reader)
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      next if status || Time.now < deadline
      Process.kill('KILL', -pid) rescue nil
      Process.waitpid(pid)
      raise "launcher did not exit within #{timeout}s. Output:\n#{output}"
    end
    output << read_to_eof(reader)
    [status, output]
  ensure
    reader.close unless reader.closed?
  end

  # Reads what the launcher and its worker processes wrote before exiting.
  # Stops at EOF, or after a few seconds if something still holds the pipe.
  def read_to_eof(reader, timeout = 5)
    output = +''
    deadline = Time.now + timeout
    while Time.now < deadline
      break unless reader.wait_readable(deadline - Time.now)
      output << reader.read_nonblock(65_536)
    end
    output
  rescue IOError # Including EOFError.
    output
  end

  def read_available(reader)
    reader.wait_readable(0.1) ? reader.read_nonblock(65_536) : ''
  rescue IOError # Including EOFError.
    ''
  end

  # Waits until the block returns truthy.
  def wait_for(timeout = 15)
    deadline = Time.now + timeout
    until (result = yield)
      raise 'condition not met in time' if Time.now > deadline
      sleep 0.05
    end
    result
  end

  def reload_job(job)
    Job.find_by(:id => job.id)
  end
end
