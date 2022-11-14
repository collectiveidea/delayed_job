require 'timeout'

module Delayed
  class WorkerTimeout < Timeout::Error
    attr_reader :job, :timeout_error

    def initialize(job, timeout_error)
      @job = job
      @timeout_error = timeout_error
    end

    def message
      seconds = (job.max_run_time || Delayed::Worker.max_run_time).to_i
      "#{super} (Delayed::Worker.max_run_time is only #{seconds} second#{seconds == 1 ? '' : 's'})"
    end

    delegate :backtrace, :to => :timeout_error
  end

  class FatalBackendError < RuntimeError; end
end
