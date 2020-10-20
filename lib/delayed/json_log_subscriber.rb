module Delayed
  class JsonLogSubscriber < ActiveSupport::LogSubscriber
    class << self
      def logger
        @logger ||= Delayed::Worker.logger
        @logger.formatter = Delayed::JsonFormatter.new
        @logger
      end
    end

    def logger
      JsonLogSubscriber.logger
    end

    def starting(event)
      dynamic_log(say({:log_event => 'starting', :message => 'Starting job worker'}, event.payload))
    end

    def consecutive_failures(event)
      text = "FAILED permanently because of #{event.payload[:consecutive_attempts]} consecutive failures"
      error(job_say({:log_event => 'consecutive_failures', :message => text, :consecutive_attempts => event.payload[:consecutive_attempts]}, event.payload))
    end

    def running(event)
      dynamic_log(job_say({:log_event => 'running', :message => 'RUNNING'}, event.payload))
    end

    def completed(event)
      runtime = format('%.4f', event.payload[:runtime])
      dynamic_log(job_say({:log_event => 'completed', :message => "COMPLETED after #{runtime}", :runtime => runtime}, event.payload))
    end

    def failed_permanently(event)
      text = "FAILED permanently with #{event.payload[:error_name]}: #{event.payload[:error_message]}"
      error(job_say({:log_event => 'failed_permanently', :message => text, :error_name => event.payload[:error_name], :error_message => event.payload[:error_message]}, event.payload))
    end

    def failed(event)
      text = "FAILED (#{event.payload[:attempts]} prior attempts) with #{event.payload[:error_name]}: #{event.payload[:error_message]}"
      error(job_say({:log_event => 'failed', :message => text, :attempts => event.payload[:attempts], :error_name => event.payload[:error_name], :error_message => event.payload[:error_message]}, event.payload))
    end

    def exiting(event)
      dynamic_log(say({:log_event => 'exiting', :message => 'Exiting...'}, event.payload))
    end

    def no_jobs_available(event)
      dynamic_log(say({:log_event => 'no_jobs_available', :message => 'No more jobs available. Exiting'}, event.payload))
    end

    def jobs_processed(event)
      rate = format('%.4f', event.payload[:count] / event.payload[:realtime])
      text = format("#{event.payload[:count]} jobs processed at #{rate} j/s, %d failed", event.payload[:faild])
      dynamic_log(say({:log_event => 'jobs_processed', :message => text, :count => event.payload[:count], :rate => rate, :faild_no => event.payload[:faild]}, event.payload))
    end

    def failure_callback_error(event)
      text = "Error when running failure callback: #{event.payload[:error]}"
      error(say({:log_event => 'failure_callback_error', :message => text, :error_message => event.payload[:error]}, event.payload))
    end

    def error_backtrace(event)
      error(say({:log_event => 'error_backtrace', :message => event.payload[:error_backtrace], :error_backtrace => event.payload[:error_backtrace]}, event.payload))
    end

    def reserving_error(event)
      text = "Error while reserving job: #{event.payload[:error]}"
      error(say({:log_event => 'reserving_error', :message => text, :error_message => event.payload[:error]}, event.payload))
    end

  private

    def dynamic_log(log)
      logger.send(log_level, log)
    end

    def log_level
      level = Delayed::Worker.default_log_level
      unless level.is_a?(String)
        say 'Usage of Fixnum log levels is deprecated'
        level = Delayed::Worker::DEFAULT_LOG_LEVEL
      end
      level
    end

    def job_say(log, payload = {})
      log[:message] = "Job #{payload[:dj_name]} (id=#{payload[:dj_id]})#{say_queue(payload[:dj_queue])} #{log[:message]}"
      log[:name]    = payload[:dj_name]
      log[:id]      = payload[:dj_id]
      log[:queue]   = payload[:dj_queue]
      say(log, payload)
    end

    def say(log, payload = {})
      log[:message]    = "#{payload[:dj_time]}: [Worker(#{payload[:dj_worker]})] #{log[:message]}"
      log[:dj_worker]  = payload[:dj_worker]
      log[:dj_time]    = payload[:dj_time]
      log
    end

    def say_queue(queue)
      " (queue=#{queue})" if queue
    end
  end
end
