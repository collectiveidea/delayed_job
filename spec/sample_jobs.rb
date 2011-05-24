class NamedJob < Struct.new(:perform)
  def display_name
    'named_job'
  end
end

class SimpleJob
  cattr_accessor :runs; self.runs = 0
  def perform; @@runs += 1; end
end

class ErrorJob
  cattr_accessor :runs; self.runs = 0
  def perform; raise 'did not work'; end
end

class CustomRescheduleJob < Struct.new(:offset)
  cattr_accessor :runs; self.runs = 0
  def perform; raise 'did not work'; end
  def reschedule_at(time, attempts); time + offset; end
end

class LongRunningJob
  def perform; sleep 250; end
end

class OnPermanentFailureJob < SimpleJob
  def failure; end
  def max_attempts; 1; end
end

module M
  class ModuleJob
    cattr_accessor :runs; self.runs = 0
    def perform; @@runs += 1; end
  end
end

class CallbackJob
  cattr_accessor :messages

  def enqueue(job)
    self.class.messages << 'enqueue'
  end

  def before(job)
    self.class.messages << 'before'
  end

  def perform
    self.class.messages << 'perform'
  end

  def after(job)
    self.class.messages << 'after'
  end

  def success(job)
    self.class.messages << 'success'
  end

  def error(job, error)
    self.class.messages << "error: #{error.class}"
  end

  def failure(job)
    self.class.messages << 'failure'
  end
end

class EnqueueJobMod < SimpleJob
  def enqueue(job)
    job.run_at = 20.minutes.from_now
  end
end
