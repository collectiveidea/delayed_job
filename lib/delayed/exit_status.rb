module Delayed
  # Exit statuses of a forked child process that aren't crashes, e.g. for a
  # process_exited subscriber deciding how loudly to report an exit.
  module ExitStatus
    # A child promoted to mold forked none (its promotion was cancelled by a
    # signal, or its threads didn't stop); the parent retries the promotion.
    PROMOTION_FAILED = 75

    # A child whose job threads didn't stop (a job ignored its interrupt):
    # not a clean exit, so the parent recovers the jobs it held, counting a
    # failed attempt.
    JOBS_STUCK = 76
  end
end
