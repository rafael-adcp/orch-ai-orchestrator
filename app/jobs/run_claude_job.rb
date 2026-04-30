class RunClaudeJob < ApplicationJob
  queue_as :claude

  # One task per repo at a time.
  limits_concurrency to: 1, key: ->(task_id) { AiTask.find(task_id).repo_path }

  # Solid Queue is the single source of truth for the cooldown and the
  # attempt count. The UI reads scheduled_at off the SQ job to display
  # "next retry at X" — nothing in our code mirrors these numbers.
  retry_on Claude::UsageLimitError, wait: 30.minutes, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(task_id)
    ClaudeRunner.new(AiTask.find(task_id)).call
  end
end
