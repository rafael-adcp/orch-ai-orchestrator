class RunClaudeJob < ApplicationJob
  queue_as :claude

  # One task per repo at a time.
  limits_concurrency to: 1, key: ->(task_id) { AiTask.find(task_id).repo_path }

  discard_on ActiveRecord::RecordNotFound

  def perform(task_id)
    task = AiTask.find(task_id)
    ClaudeRunner.new(task).call
    task.schedule_recurrence! if task.recurring?
  rescue Claude::UsageLimitError => e
    raise if executions >= Rails.application.config.orchestrator[:max_limit_retries]
    retry_job(wait: limit_wait(e.reset_at))
  end

  private

  def limit_wait(reset_at)
    return 30.minutes unless reset_at
    [ (reset_at - Time.current).ceil, 60 ].max
  end
end
