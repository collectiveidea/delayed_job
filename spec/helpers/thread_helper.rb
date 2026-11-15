# Runs dispatchers in specs, and waits for conditions.
module ThreadHelper
  # Skips the example where QUIT can't be trapped: no such signal, or the
  # JVM (JRuby), which reserves it (see Delayed.check_trappable!).
  def skip_unless_quit_trappable
    skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
    skip 'the JVM reserves SIGQUIT' if RUBY_ENGINE == 'jruby'
  end

  # Waits until the block returns true; raises Timeout::Error after
  # `timeout` seconds.
  def wait_until(timeout = 5)
    Timeout.timeout(timeout) { sleep 0.01 until yield }
  end

  # Runs the dispatcher on a thread of its own and returns the thread. It is
  # stopped and joined after the example (see #stop_running_dispatchers), so
  # a failed example doesn't leave it running jobs during the next one.
  def run_in_thread(dispatcher = self.dispatcher)
    Thread.new { dispatcher.run }.tap do |thread|
      thread.report_on_exception = false
      running_dispatchers << [dispatcher, thread]
    end
  end

  # Runs the dispatcher until no job is left (Worker.exit_on_complete).
  def run_to_completion(dispatcher = self.dispatcher, timeout = 10)
    Delayed::Worker.exit_on_complete = true
    Timeout.timeout(timeout) { dispatcher.run }
  end

  def running_dispatchers
    @running_dispatchers ||= []
  end

  # Releases the blocking test jobs, then stops and joins every dispatcher
  # #run_in_thread started.
  def stop_running_dispatchers
    return if running_dispatchers.empty?
    GateJob.release = true
    BlockingJob.release = true
    running_dispatchers.each do |dispatcher, thread|
      dispatcher.stop
      begin
        thread.join(10)
      rescue Exception # rubocop:disable Lint/RescueException
        nil # The example already failed, or checked the error.
      end
    end
  end
end
