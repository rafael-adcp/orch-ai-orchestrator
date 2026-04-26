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
                       clock: Time)
    @task, @sub, @build, @logs, @limits, @clock =
      task, subprocess, command_builder, log_writer, limit_detector, clock
  end

  def call
    start
    result, limit_hit = stream
    finalize(result.exit_status, limit_hit)
  end

  private

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
    @limits.detect(line)
  end

  def finalize(exit_status, limit_hit)
    if limit_hit
      @task.mark_failed!(error: "claude usage limit hit: #{limit_hit}", now: @clock.current)
      raise Claude::UsageLimitError, limit_hit.to_s
    elsif exit_status.zero?
      @task.mark_done!(now: @clock.current)
    else
      @task.mark_failed!(error: "exit code #{exit_status}", now: @clock.current)
    end
  end
end
