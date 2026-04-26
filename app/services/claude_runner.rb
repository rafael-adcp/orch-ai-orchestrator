# Orchestrates one task's execution: builds the command, streams the
# subprocess, writes a log file, and updates the task record.
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
    # UsageLimitError is the runner's contract with Solid Queue's retry_on;
    # RecordNotFound is handled by the job's discard_on. Re-raise untouched.
    raise
  rescue StandardError => e
    # Anything else (DB hiccup, log I/O, bug) would otherwise leave the task
    # orphaned in :running. Tell-don't-ask: the runner owns terminal state.
    mark_failed_safely("unexpected error: #{e.class}: #{e.message}")
    raise
  end

  private

  def mark_failed_safely(message)
    return unless @task.can_transition?(AiTask::FAILED)
    @task.mark_failed!(error: message, now: @clock.current)
  rescue StandardError
    # If we can't even record the failure, don't mask the original error.
  end

  def start
    path = @logs.path_for(@task.id)
    @task.mark_running!(now: @clock.current, log_path: path)
    @logs.write_header(path, "===== task #{@task.id} =====\n")
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

  # Terminal state is decided by, in order:
  #   1. usage limit phrase  -> :failed + raise (Solid Queue retries)
  #   2. non-zero exit code  -> :failed
  #   3. BLOCKED sentinel    -> :failed (Claude told us it stopped early)
  #   4. SUCCESS sentinel    -> :done
  #   5. nothing of the above (exit 0, no sentinel) -> :needs_review
  #
  # Case 5 is the whole point of the sentinel: `claude -p` exits 0 even when
  # it hits --max-turns, asks a clarifying question, or no-ops. Without a
  # success marker we cannot honestly call the task done.
  def finalize(exit_status, limit_hit, success_result)
    if limit_hit
      @task.mark_failed!(error: "claude usage limit hit: #{limit_hit}", now: @clock.current)
      raise Claude::UsageLimitError, limit_hit.to_s
    elsif exit_status.nonzero?
      @task.mark_failed!(error: "exit code #{exit_status}", now: @clock.current)
    elsif success_result&.blocked?
      @task.mark_failed!(error: "blocked: #{success_result.reason}", now: @clock.current)
    elsif success_result&.success?
      @task.mark_done!(now: @clock.current)
    else
      @task.mark_needs_review!(
        reason: "no completion sentinel printed (exit 0); cannot confirm task was completed",
        now: @clock.current
      )
    end
  end
end
