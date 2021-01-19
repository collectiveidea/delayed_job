require 'timeout'

module Delayed
  class WorkerTimeout < Timeout::Error
    attr_reader :job, :seconds

    def initialize(job, seconds)
      @job = job
      @seconds = seconds
    end

    def message
      "execution expired (#{source_max_run_time} is only #{seconds_to_s}"
    end

  private

    def source_max_run_time
      job_timeout? ? "#{job.name}#max_run_time" : 'Delayed::Worker.max_run_time'
    end

    def job_timeout?
      job.max_run_time
    end

    def seconds_to_s
      "#{@seconds} second#{seconds == 1 ? '' : 's'}"
    end
  end

  class FatalBackendError < RuntimeError; end
end
