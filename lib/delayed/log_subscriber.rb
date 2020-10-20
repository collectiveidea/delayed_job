module Delayed
  class LogSubscriber < ActiveSupport::LogSubscriber
    class << self
      def logger
        @logger ||= Delayed::Worker.logger
      end
    end

    def logger
      LogSubscriber.logger
    end

    def starting(event)
      dynamic_log(say('Starting job worker', event.payload))
    end

    def consecutive_failures(event)
      text = "FAILED permanently because of #{event.payload[:consecutive_attempts]} consecutive failures"
      error(job_say(text, event.payload))
    end

    def running(event)
      dynamic_log(job_say('RUNNING', event.payload))
    end

    def completed(event)
      dynamic_log(job_say(format('COMPLETED after %.4f', event.payload[:runtime]), event.payload))
    end

    def failed_permanently(event)
      text = "FAILED permanently with #{event.payload[:error_name]}: #{event.payload[:error_message]}"
      error(job_say(text, event.payload))
    end

    def failed(event)
      text = "FAILED (#{event.payload[:attempts]} prior attempts) with #{event.payload[:error_name]}: #{event.payload[:error_message]}"
      error(job_say(text, event.payload))
    end

    def exiting(event)
      dynamic_log(say('Exiting...', event.payload))
    end

    def no_jobs_available(event)
      dynamic_log(say('No more jobs available. Exiting', event.payload))
    end

    def jobs_processed(event)
      text = format("#{event.payload[:count]} jobs processed at %.4f j/s, %d failed", event.payload[:count] / event.payload[:realtime], event.payload[:faild])
      dynamic_log(say(text, event.payload))
    end

    def failure_callback_error(event)
      text = "Error when running failure callback: #{event.payload[:error]}"
      error(say(text, event.payload))
    end

    def error_backtrace(event)
      error(say(event.payload[:error_backtrace], event.payload))
    end

    def reserving_error(event)
      text = "Error while reserving job: #{event.payload[:error]}"
      error(say(text, event.payload))
    end

  private

    def dynamic_log(text)
      logger.send(log_level, text)
    end

    def log_level
      level = Delayed::Worker.default_log_level
      unless level.is_a?(String)
        say 'Usage of Fixnum log levels is deprecated'
        level = Delayed::Worker::DEFAULT_LOG_LEVEL
      end
      level
    end

    def job_say(text, payload = {})
      text = "Job #{payload[:dj_name]} (id=#{payload[:dj_id]})#{say_queue(payload[:dj_queue])} #{text}"
      say(text, payload)
    end

    def say(text, payload = {})
      text = "[Worker(#{payload[:dj_worker]})] #{text}"
      puts text unless payload[:quiet]
      "#{payload[:dj_time]}: #{text}"
    end

    def say_queue(queue)
      " (queue=#{queue})" if queue
    end
  end
end
