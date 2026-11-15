# Jobs used by the process-level specs. Each run is recorded in the runs table.
module ProcessJobs
  def self.record(key, started)
    Delayed::Backend::SqliteFile::Run.create!(
      :key => key, :pid => Process.pid, :worker => Thread.current.name,
      :started => started, :finished => Time.now.to_f
    )
  end

  # Sleeps, then records its run.
  SleepJob = Struct.new(:key, :seconds) do
    def perform
      started = Time.now.to_f
      sleep seconds
      ProcessJobs.record(key, started)
    end
  end

  # Kills the process running it with `signal` on its first attempt;
  # succeeds on later attempts.
  KillJob = Struct.new(:key, :signal) do
    def perform
      Process.kill(signal, Process.pid) if Delayed::Job.find_by(:id => job_id).attempts.zero?
      sleep 1 # let the signal arrive
      ProcessJobs.record(key, Time.now.to_f)
    end

    attr_accessor :job_id

    def before(job)
      self.job_id = job.id
    end
  end

  # Exits the process running it with `status`, skipping at_exit hooks.
  ExitJob = Struct.new(:key, :status) do
    def perform
      exit!(status)
    end
  end

  # Runs a command and records whether its status was read: "<key>:true".
  SystemJob = Struct.new(:key) do
    def perform
      started = Time.now.to_f
      system('true')
      ProcessJobs.record("#{key}:#{$?&.success? || false}", started)
    end
  end

  # Leaves the process running it unsafe to fork (see
  # Delayed::Worker.no_longer_fork_safe!), then records its run.
  ForkUnsafeJob = Struct.new(:key) do
    def perform
      Delayed::Worker.no_longer_fork_safe!
      ProcessJobs.record(key, Time.now.to_f)
    end
  end

  # Ignores the shutdown interrupt, so only a kill stops it.
  StubbornJob = Struct.new(:key) do
    def perform
      deadline = Time.now + 60
      begin
        sleep 0.1 while Time.now < deadline
      rescue Delayed::ShutdownInterrupt
        retry
      end
    end
  end

  # Exits the process running it with `status` on its first run (marked by
  # creating `marker`); records its run on later ones.
  ExitOnceJob = Struct.new(:key, :status, :marker) do
    def perform
      unless File.exist?(marker)
        File.write(marker, '')
        exit!(status)
      end
      ProcessJobs.record(key, Time.now.to_f)
    end
  end

  # Sleeps past its own max_run_time, so it times out (a failed attempt).
  TimeoutJob = Struct.new(:key, :seconds, :max_run_time) do
    def perform
      sleep seconds
      ProcessJobs.record(key, Time.now.to_f)
    end
  end

  # Defers every interrupt (like a call hung in C code): neither the
  # shutdown interrupt nor process exit stops it, only SIGKILL.
  UnkillableJob = Struct.new(:key) do
    def perform
      Thread.handle_interrupt(Object => :never) do
        deadline = Time.now + 60
        sleep 0.1 while Time.now < deadline
      end
    end
  end

  # Freezes the process running it (SIGSTOP), like a hung native call
  # holding the GVL: it can neither run nor exit, so only the parent's kill
  # (SIGKILL) ends it.
  FreezeJob = Struct.new(:key) do
    def perform
      Process.kill('STOP', Process.pid)
    end
  end
end
