class RunClaudeJob < ApplicationJob
  queue_as :claude

  # One task per repo at a time. `duration:` is the *upper bound* on how
  # long the semaphore is held — Solid Queue's default is 3 minutes, far
  # shorter than a real Claude task, so the lock would expire mid-run and
  # release the next per-repo job. 24h is a safe ceiling: longer than any
  # realistic task, short enough that a truly orphaned lock eventually frees.
  limits_concurrency to: 1, duration: 24.hours,
                     key: ->(task_id) { AiTask.find(task_id).repo_path }

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
