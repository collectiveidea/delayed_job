module Delayed
  # Implements an auto-reset event.
  #
  # Event is a semaphore-like thread synchronization object with auto-reset
  # capability. One thread sets the event and another one waits on it with a
  # timeout.
  class Event
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @value = false
    end

    # Set the event and wake up one thread.
    def set!
      @mutex.synchronize do
        @value = true
        @condition.signal
      end
    end

    # Wait for event to be set.
    #
    # Event#wait will wait until the event is set, with a timeout. If the
    # timeout elapses it returns false. Otherwise it returns true and resets the
    # event.
    def wait(timeout)
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      @mutex.synchronize do
        until @value
          timeout = target - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if timeout <= 0
          @condition.wait(@mutex, timeout)
        end
        result = @value
        @value = false
        result
      end
    end
  end
end
