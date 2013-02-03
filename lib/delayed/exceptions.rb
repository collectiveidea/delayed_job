require 'timeout'

module Delayed
  class WorkerTimeout < Timeout::Error
    def message
      "#{super} (Delayed::Worker.max_run_time is only #{Delayed::Worker.max_run_time.to_i} seconds)"
    end
  end
end
