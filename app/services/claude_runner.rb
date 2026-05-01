# Orchestrates one task's execution: builds the command, streams the
# subprocess, writes a log file, and stamps the AiTask with a *terminal*
# outcome. It deliberately does NOT track "running" / "scheduled-retry"
# state on AiTask — Solid Queue owns that, and the TaskStatus presenter
# reads it back when the UI asks.
class ClaudeRunner
  class << self
    attr_accessor :subprocess_override
  end

  def initialize(task, subprocess: self.class.subprocess_override || Subprocess.new,
                       command_builder: ClaudeCommand.new,
                       log_writer: LogWriter.new,
                       limit_detector: LimitDetector.new,
                       success_detector: SuccessDetector.new,
                       clock: Time)
    @task, @sub, @build, @logs, @limits, @success, @clock =
      task, subprocess, command_builder, log_writer, limit_detector, success_detector, clock
  end

  def call
    start
    result, limit_hit = stream
    finalize(result.exit_status, limit_hit, @success.result)
  rescue Claude::UsageLimitError, ActiveRecord::RecordNotFound
    # UsageLimitError flows through to RunClaudeJob.retry_on, which
    # re-enqueues at SQ's level. We do NOT mark AiTask failed — the
    # task is still in_flight; SQ owns the cooldown. RecordNotFound is
    # handled by the job's discard_on. Re-raise untouched.
    raise
  rescue StandardError => e
    mark_failed_safely("unexpected error: #{e.class}: #{e.message}")
    raise
  end

  private

  def mark_failed_safely(message)
    log_event("error: #{message}")
    return unless @task.in_flight?
    @task.mark_failed!(error: message, now: @clock.current)
  rescue StandardError
    # If we can't even record the failure, don't mask the original error.
  end

  def start
    path = @logs.path_for(@task.id)
    @task.mark_started!(now: @clock.current, log_path: path)
    @logs.ensure_dir(path)
    @logs.append(path, "\n#{"=" * 60}\n")
    @logs.event(path, "starting work on task #{@task.id} (repo=#{@task.repo_path})")
    @logs.append(path, "#{"=" * 60}\n\n")
  end

  def stream
    limit_hit = nil
    result = @sub.run(@build.build(@task), cwd: @task.repo_path,
                      on_line: ->(line) { limit_hit ||= consume(line) })
    [ result, limit_hit ]
  end

  def consume(line)
    @logs.append(@task.log_path, line)
    @success.consume(line)
    @limits.detect(line)
  end

  # Outcome decision, in priority order:
  #   1. usage limit phrase  -> raise (SQ retries; AiTask stays in_flight)
  #   2. non-zero exit code  -> failed
  #   3. BLOCKED sentinel    -> blocked
  #   4. SUCCESS sentinel    -> done
  #   5. exit 0, no sentinel -> needs_review
  def finalize(exit_status, limit_hit, success_result)
    if limit_hit
      log_event("usage limit hit (#{limit_hit}); Solid Queue will retry")
      raise Claude::UsageLimitError.new(limit_hit.to_s, reset_at: limit_hit.reset_at)
    elsif exit_status.nonzero?
      mark_failed("exit code #{exit_status}")
    elsif success_result&.blocked?
      log_event("task blocked: #{success_result.reason}")
      @task.mark_blocked!(reason: success_result.reason, now: @clock.current)
    elsif success_result&.success?
      log_event("task completed successfully")
      @task.mark_done!(now: @clock.current)
    else
      log_event("task ended with exit 0 but no completion sentinel; needs review")
      @task.mark_needs_review!(
        reason: "no completion sentinel printed (exit 0); cannot confirm task was completed",
        now: @clock.current
      )
    end
  end

  def mark_failed(message)
    log_event("task failed: #{message}")
    @task.mark_failed!(error: message, now: @clock.current)
  end

  def log_event(message)
    return unless @task.log_path
    @logs.event(@task.log_path, message)
  rescue StandardError
    # Logging is best-effort; never let it mask the real outcome.
  end
end
