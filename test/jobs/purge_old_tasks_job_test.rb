require "test_helper"

class PurgeOldTasksJobTest < ActiveSupport::TestCase
  setup do
    AiTask.create!(repo_path: "/tmp/r", prompt: "old",   outcome: AiTask::DONE,   finished_at: 10.hours.ago)
    AiTask.create!(repo_path: "/tmp/r", prompt: "fresh", outcome: AiTask::DONE,   finished_at: 1.hour.ago)
    AiTask.create!(repo_path: "/tmp/r", prompt: "live",  outcome: AiTask::IN_FLIGHT)
  end

  test "default invocation drops only tasks older than the configured purge age" do
    PurgeOldTasksJob.perform_now

    refute AiTask.where(prompt: "old").exists?, "tasks past the default cutoff are dropped"
    assert AiTask.where(prompt: "fresh").exists?, "tasks within the cutoff stay"
    assert AiTask.where(prompt: "live").exists?,  "in-flight tasks are never touched"
  end

  test "accepts an explicit duration to widen the cutoff" do
    PurgeOldTasksJob.perform_now(older_than: 30.minutes)

    refute AiTask.where(prompt: "old").exists?
    refute AiTask.where(prompt: "fresh").exists?, "30min cutoff catches the 1-hour-old task too"
    assert AiTask.where(prompt: "live").exists?
  end

  test "runs on the maintenance queue" do
    assert_equal "maintenance", PurgeOldTasksJob.new.queue_name
  end

  test "never deletes recurring tasks even when past the cutoff" do
    AiTask.create!(repo_path: "/tmp/r", prompt: "repeat",
                   outcome: AiTask::DONE, finished_at: 10.hours.ago,
                   recurring_interval_hours: 4)

    PurgeOldTasksJob.perform_now(older_than: 1.hour)

    assert AiTask.where(prompt: "repeat").exists?, "recurring tasks must survive purge"
  end
end
