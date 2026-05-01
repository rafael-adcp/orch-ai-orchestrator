# Combines the application-level outcome owned by AiTask with the
# execution mechanics owned by Solid Queue. Single place that answers
# "what should the UI show?" and "is the task busy / waiting / done?"
# without AiTask shadowing SQ's job table.
class TaskStatus
  # Labels the UI renders. Anything other than :in_flight on the AiTask
  # short-circuits to the matching label; otherwise we ask SQ.
  LABELS = %i[queued running retrying done failed needs_review blocked cancelled].freeze
  QUEUED, RUNNING, RETRYING, DONE, FAILED, NEEDS_REVIEW, BLOCKED, CANCELLED = LABELS

  def initialize(task, sq_job_class: SolidQueue::Job)
    @task, @sq_job_class = task, sq_job_class
  end

  def label
    return @task.outcome.to_sym unless @task.in_flight?
    return QUEUED unless sq_job
    return RUNNING  if sq_job.claimed?
    return RETRYING if retry_pending?
    return FAILED   if sq_job.failed?
    QUEUED
  end

  def running?       = label == RUNNING
  def retrying?      = label == RETRYING
  def queued?        = label == QUEUED
  def cancellable?   = @task.in_flight? && !running?
  # A task is offered the "Retry" affordance once it has finished — at
  # either layer. That includes the awkward case where Solid Queue
  # exhausted its retries (job :failed) while AiTask is still in_flight;
  # the presenter is the only place that reconciles the two, so it owns
  # this rule. Cancelled tasks are excluded because the user explicitly
  # stopped them.
  RETRYABLE_LABELS = %i[done failed needs_review blocked].freeze
  def retryable?     = RETRYABLE_LABELS.include?(label)

  def attempts
    return 0 unless sq_job
    Integer(sq_job.arguments&.dig("executions") || 0) + 1
  end

  def next_retry_at
    sq_job&.scheduled_at if retrying?
  end

  def discard_queued_job
    sq_job&.discard if sq_job && !sq_job.claimed?
  rescue StandardError
    # Best-effort cleanup; SQ may have already finished or destroyed it.
  end

  private

  def sq_job
    return @sq_job if defined?(@sq_job)
    id = @task.active_job_id
    @sq_job = id && @sq_job_class.where(active_job_id: id).order(id: :desc).first
  end

  def retry_pending?
    sq_job.scheduled? && attempts > 1
  end
end
