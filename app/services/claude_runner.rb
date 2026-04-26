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
                       command_builder: ClaudeCommand.new, clock: Time)
    @task  = task
    @sub   = subprocess
    @build = command_builder
    @clock = clock
  end

  def call
    mark_running
    result, limit_hit = stream
    finalize(result.exit_status, limit_hit)
  end

  private

  def mark_running
    @task.update!(status: "running", started_at: @clock.current, log_path: log_file)
    FileUtils.mkdir_p(File.dirname(log_file))
    File.write(log_file, header)
  end

  def stream
    limit_hit = nil
    argv = @build.build(@task)
    result = @sub.run(argv, cwd: @task.repo_path, on_line: ->(line) {
      File.open(log_file, "a") { |f| f.write(line); f.flush }
      limit_hit ||= detect_limit(line)
    })
    [ result, limit_hit ]
  end

  def finalize(exit_status, limit_hit)
    if limit_hit
      fail_task("claude usage limit hit: #{limit_hit}")
      raise Claude::UsageLimitError, limit_hit
    elsif exit_status.zero?
      done_task
    else
      fail_task("exit code #{exit_status}")
    end
  end

  def detect_limit(line)
    LIMIT_PATTERNS.find { |re| line.match?(re) }&.source
  end

  def fail_task(msg)
    @task.update!(status: "failed", error: msg, finished_at: @clock.current)
  end

  def done_task
    @task.update!(status: "done", finished_at: @clock.current)
  end

  def log_file
    @log_file ||= Rails.root.join("log", "tasks", "#{@task.id}.log").to_s
  end

  def header
    "===== task #{@task.id} =====\n"
  end
end
