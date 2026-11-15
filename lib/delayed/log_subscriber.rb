require 'active_support/log_subscriber'

module Delayed
  # Logs `*.delayed_job` events with durations. Not attached by default:
  #
  #   Delayed::LogSubscriber.attach_to :delayed_job
  class LogSubscriber < ActiveSupport::LogSubscriber
    def logger
      Delayed::Worker.logger
    end

    def process_started(event)
      p = event.payload
      log(:info) { "Started #{p[:dispatcher]} (pid #{p[:pid]}, #{p[:threads]} thread(s), queues=#{queues(p[:queues])})" }
    end

    def process_stopped(event)
      p = event.payload
      error_text = p[:error] ? " with #{p[:error].class}: #{p[:error].message}" : ''
      log(:info) { "Stopped #{p[:dispatcher]} (pid #{p[:pid]})#{error_text}" }
    end

    def jobs_reserved(event)
      p = event.payload
      log(:debug) { "#{p[:dispatcher]} reserved #{p[:reserved]} of #{p[:requested]} job(s)#{raised(event)} (#{ms(event)})" }
    end

    def job_performed(event)
      p = event.payload
      outcome = if p[:exception] then "was interrupted (#{p[:exception].first})"
      elsif p[:success] then 'succeeded'
      else 'failed'
      end
      log(:debug) { "#{job(p[:job])} #{outcome} on #{p[:worker]} (#{ms(event)})" }
    end

    def job_attempt_failed(event)
      p = event.payload
      log(:warn) { "#{job(p[:job])} failed attempt #{p[:attempts]} on #{p[:worker]} with #{p[:error].class}: #{p[:error].message}" }
    end

    def job_failed(event)
      p = event.payload
      log(:error) { "#{job(p[:job])} failed permanently on #{p[:worker]}" }
    end

    def job_lock_lost(event)
      p = event.payload
      log(:warn) { "#{job(p[:job])} was #{p[:outcome]} on #{p[:worker]} after its lock was taken over; result discarded" }
    end

    def thread_error(event)
      p = event.payload
      log(:error) { "#{p[:context]} error in #{p[:dispatcher] || p[:worker]}: #{p[:error].class}: #{p[:error].message}" }
    end

    def jobs_interrupted(event)
      p = event.payload
      log(:warn) { "#{p[:dispatcher]} interrupted #{p[:jobs]} running job(s) (#{p[:reason]})" }
    end

    def jobs_released(event)
      p = event.payload
      log(:info) { "Released #{p[:count]} job(s) of #{Array(p[:workers]).join(', ')} (#{p[:reason]})" }
    end

    def process_exited(event)
      p = event.payload
      uptime = p[:uptime] ? format(' after %.1fs', p[:uptime]) : ''
      log(:info) { "Child process #{p[:worker]} (pid #{p[:pid]}) exited#{uptime}: #{p[:status]}; #{respawn(p[:respawn_in])}" }
    end

    def process_spawned(event)
      p = event.payload
      replaces = p[:replaces_pid] ? " replacing pid #{p[:replaces_pid]}" : ''
      mold = p[:mold_pid] ? " from mold (pid #{p[:mold_pid]})" : ''
      log(:info) { "Child process #{p[:worker]} (pid #{p[:pid]}) spawned#{mold}#{replaces}" }
    end

    def mold_promoted(event)
      p = event.payload
      log(:info) { "Child process #{p[:worker]} (pid #{p[:pid]}) promoted to mold after #{p[:jobs]} job(s) (#{p[:trigger]})" }
    end

    def mold_activated(event)
      p = event.payload
      log(:info) { "Mold (pid #{p[:pid]}) activated, generation #{p[:generation]}" }
    end

    def mold_refork_completed(event)
      p = event.payload
      log(:info) { "Mold (pid #{p[:pid]}) refork completed, generation #{p[:generation]}" }
    end

    def mold_lost(event)
      p = event.payload
      log(:warn) { "Mold (pid #{p[:pid]}) lost (#{p[:reason]}), generation #{p[:generation]}; promoting a new mold in #{p[:retry_in]}s" }
    end

    def mold_promotion_failed(event)
      p = event.payload
      log(:warn) { "Promotion of child process (pid #{p[:pid]}) to mold failed (#{p[:reason]}); retrying in #{p[:retry_in]}s" }
    end

    def mold_retired(event)
      log(:info) { "Mold (pid #{event.payload[:pid]}) retired" }
    end

    def job_stuck(event)
      p = event.payload
      # Published from another thread, so only the job's name is passed.
      log(:error) { "#{p[:job_name]} is stuck on #{p[:worker]}: running past its max_run_time (#{p[:max_run_time]}s)" }
    end

    if respond_to?(:subscribe_log_level)
      subscribe_log_level :jobs_reserved, :debug
      subscribe_log_level :job_performed, :debug
    end

  private

    # ActiveSupport's level helpers (info, error, ...) vary across versions.
    def log(level, &block)
      logger.public_send(level, &block) if logger
    end

    def respawn(respawn_in)
      return 'not replaced' if respawn_in.nil?
      respawn_in.zero? ? 'replacing it' : "replacing it in #{respawn_in}s"
    end

    def raised(event)
      exception = event.payload[:exception]
      exception ? " - #{exception.first}: #{exception.last}" : ''
    end

    def job(job)
      return 'Job' unless job
      "Job #{job.name} (id=#{job.id})#{" (queue=#{job.queue})" if job.queue}"
    end

    def queues(queues)
      queues.nil? || queues.empty? ? '*' : queues.join(',')
    end

    def ms(event)
      format('%.1fms', event.duration)
    end
  end
end
