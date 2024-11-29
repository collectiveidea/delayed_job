NamedJob = Struct.new(:perform)
class NamedJob
  def display_name
    'named_job'
  end
end

class SimpleJob
  cattr_accessor :runs
  @runs = 0
  def perform
    self.class.runs += 1
  end
end

class NamedQueueJob < SimpleJob
  def queue_name
    'job_tracking'
  end
end

class ErrorJob
  cattr_accessor :runs
  @runs = 0
  def perform
    raise Exception, 'did not work'
  end
end

CustomRescheduleJob = Struct.new(:offset)
class CustomRescheduleJob
  cattr_accessor :runs
  @runs = 0
  def perform
    raise 'did not work'
  end

  def reschedule_at(time, _attempts)
    time + offset
  end
end

class LongRunningJob
  def perform
    sleep 250
  end
end

class OnPermanentFailureJob < SimpleJob
  attr_writer :raise_error

  def initialize
    @raise_error = false
  end

  def on_job_failure
    raise 'did not work' if @raise_error
  end

  def max_attempts
    1
  end
end

module M
  class ModuleJob
    cattr_accessor :runs
    @runs = 0
    def perform
      self.class.runs += 1
    end
  end
end

class CallbackJob
  cattr_accessor :messages

  def on_job_enqueue(_job)
    self.class.messages << 'on_job_enqueue'
  end

  def before_job_run(_job)
    self.class.messages << 'before_job_run'
  end

  def perform
    self.class.messages << 'perform'
  end

  def after_job_run(_job)
    self.class.messages << 'after_job_run'
  end

  def on_job_success(_job)
    self.class.messages << 'on_job_success'
  end

  def on_job_error(_job, error)
    self.class.messages << "on_job_error: #{error.class}"
  end

  def on_job_failure(_job)
    self.class.messages << 'on_job_failure'
  end
end

class EnqueueJobMod < SimpleJob
  def on_job_enqueue(job)
    job.run_at = 20.minutes.from_now
  end
end
