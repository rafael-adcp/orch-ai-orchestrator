# Orchestrates one task's execution: builds the command, streams the
# subprocess, writes a log file, and updates the task record.
class ClaudeRunner
  LIMIT_PATTERNS = [
    /usage limit reached/i,
    /you've hit your limit/i,
    /5-hour limit reached/i
  ].freeze

  class << self
    attr_accessor :subprocess_override
  end

  def initialize(task, subprocess: self.class.subprocess_override || Subprocess.new,
                       command_builder: ClaudeCommand.new,
                       log_writer: LogWriter.new,
                       clock: Time)
    @task, @sub, @build, @logs, @clock = task, subprocess, command_builder, log_writer, clock
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
    argv = @build.build(@task)
    result = @sub.run(argv, cwd: @task.repo_path, on_line: ->(line) {
      @logs.append(@task.log_path, line)
      limit_hit ||= detect_limit(line)
    })
    [ result, limit_hit ]
  end

  def finalize(exit_status, limit_hit)
    if limit_hit
      @task.mark_failed!(error: "claude usage limit hit: #{limit_hit}", now: @clock.current)
      raise Claude::UsageLimitError, limit_hit
    elsif exit_status.zero?
      @task.mark_done!(now: @clock.current)
    else
      @task.mark_failed!(error: "exit code #{exit_status}", now: @clock.current)
    end
  end

  def detect_limit(line)
    LIMIT_PATTERNS.find { |re| line.match?(re) }&.source
  end
end
