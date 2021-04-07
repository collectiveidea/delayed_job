module Delayed
  class PoolParser
    def add(string)
      string.split('|').each do |segment|
        queues, worker_count = segment.split(':')
        queues = ['*', '', nil].include?(queues) ? [] : queues.split(',')
        worker_count = (worker_count || 1).to_i rescue 1
        pools << [queues, worker_count]
      end
      self
    end

    def pools
      @pools ||= []
    end
  end
end
