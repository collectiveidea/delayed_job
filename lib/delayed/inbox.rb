module Delayed
  # Jobs the Dispatcher hands to one worker thread (the next job plus any
  # prefetched). #pop returns the most urgent (priority, run_at, arrival),
  # so a late-reserved urgent job doesn't wait behind prefetched ones.
  class Inbox
    # Returned by #pop once closed and empty.
    EOQ = Object.new.freeze

    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @items = [] # [sort_key, [slot, job, reserved_at]]
      @sequence = 0
      @closed = false
    end

    # reserved_at: monotonic seconds.
    def push(slot, job, reserved_at)
      @mutex.synchronize do
        @items << [[job.priority.to_i, run_at_of(job), @sequence += 1], [slot, job, reserved_at]]
        @cond.signal
      end
      self
    end

    # Blocks until a job is available; EOQ once closed and empty.
    def pop
      @mutex.synchronize do
        loop do
          unless @items.empty?
            best = @items.each_index.min_by { |index| @items[index].first }
            return @items.delete_at(best).last
          end
          return EOQ if @closed
          @cond.wait(@mutex)
        end
      end
    end

    # Non-blocking.
    def drain
      @mutex.synchronize do
        items = @items.map(&:last)
        @items.clear
        items
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @cond.broadcast
      end
    end

    def size
      @mutex.synchronize { @items.size }
    end

  private

    # Float, so any backend's time class compares; nil sorts first.
    def run_at_of(job)
      run_at = job.run_at
      run_at ? run_at.to_f : 0.0
    end
  end
end
