# Owns the "remove a task and its tail" verb. Deleting a task is more
# than `task.destroy` — there's a log file on disk and (possibly) a queued
# Solid Queue job that would otherwise fire later against a missing row.
# Tell-don't-ask: callers ask for `delete(task)` and trust this service to
# tidy every seam.
class TaskPurge
  Result      = Struct.new(:deleted, :reason, keyword_init: true) { def deleted? = deleted }
  SweepReport = Struct.new(:deleted_count, keyword_init: true)

  def self.default_age
    Rails.application.config.orchestrator[:purge_after_hours].hours
  end

  def self.delete(task)             = new.delete(task)
  def self.sweep(older_than: default_age.ago) = new.sweep(older_than: older_than)

  def delete(task)
    return refused("task is currently running; cancel it first") if running?(task)

    discard_queued_job(task)
    delete_log_file(task)
    task.destroy!
    Result.new(deleted: true)
  end

  # The sweep query already excludes IN_FLIGHT rows, so delete() can never
  # refuse here — every iteration counts as deleted.
  def sweep(older_than:)
    deleted = 0
    AiTask.where.not(outcome: AiTask::IN_FLIGHT)
          .where(recurring_interval_hours: nil)
          .where("finished_at < ?", older_than)
          .find_each do |task|
      delete(task)
      deleted += 1
    end
    SweepReport.new(deleted_count: deleted)
  end

  private

  def running?(task)
    task.in_flight? && task.status.running?
  end

  def discard_queued_job(task)
    task.status.discard_queued_job if task.in_flight?
  end

  def delete_log_file(task)
    return if task.log_path.blank?
    File.delete(task.log_path) if File.exist?(task.log_path)
  rescue SystemCallError
    # The row is the source of truth; an orphan log file is recoverable.
  end

  def refused(reason)
    Result.new(deleted: false, reason: reason)
  end
end
