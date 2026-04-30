# Owns the "remove a task and its tail" verb. Deleting a task is more
# than `task.destroy` — there's a log file on disk and (possibly) a queued
# Solid Queue job that would otherwise fire later against a missing row.
# Tell-don't-ask: callers ask for `delete(task)` and trust this service to
# tidy every seam.
class TaskPurge
  Result = Struct.new(:deleted, :reason, keyword_init: true) do
    def deleted? = deleted
  end

  def self.delete(task) = new.delete(task)

  def delete(task)
    return refused("task is currently running; cancel it first") if running?(task)

    discard_queued_job(task)
    delete_log_file(task)
    task.destroy!
    Result.new(deleted: true)
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
