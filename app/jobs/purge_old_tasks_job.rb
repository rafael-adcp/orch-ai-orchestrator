# Recurring sweep that drops tasks finished more than DEFAULT_AGE ago,
# along with their log files and any lingering SQ job. Solid Queue's own
# `clear_finished_in_batches` recurring task takes care of the SQ tables;
# this job is purely about AiTask + the on-disk logs.
class PurgeOldTasksJob < ApplicationJob
  queue_as :maintenance

  def perform(older_than: TaskPurge.default_age.ago)
    cutoff = older_than.is_a?(ActiveSupport::Duration) ? older_than.ago : older_than
    TaskPurge.sweep(older_than: cutoff)
  end
end
