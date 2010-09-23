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
  def on_permanent_failure
  end
end

module M
  class ModuleJob
    cattr_accessor :runs; self.runs = 0
    def perform; @@runs += 1; end    
  end
end

class SuccessfulCallbackJob
  cattr_accessor :messages

  def before(job)
    SuccessfulCallbackJob.messages << 'before perform'
  end
  
  def perform
    SuccessfulCallbackJob.messages << 'perform'
  end
  
  def after(job, error = nil)
    SuccessfulCallbackJob.messages << 'after perform'
  end
  
  def success(job)
    SuccessfulCallbackJob.messages << 'success!'
  end
  
  def failure(job, error)
    SuccessfulCallbackJob.messages << "error: #{error.class}"
  end
end

class FailureCallbackJob < SuccessfulCallbackJob
  def perform
     raise "failure job"
  end
end
