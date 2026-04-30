require "test_helper"

class PurgeOldTasksJobTest < ActiveSupport::TestCase
  setup do
    AiTask.create!(repo_path: "/tmp/r", prompt: "old",   outcome: AiTask::DONE,   finished_at: 60.days.ago)
    AiTask.create!(repo_path: "/tmp/r", prompt: "fresh", outcome: AiTask::DONE,   finished_at: 1.day.ago)
    AiTask.create!(repo_path: "/tmp/r", prompt: "live",  outcome: AiTask::IN_FLIGHT)
  end

  test "default invocation drops only tasks older than DEFAULT_AGE" do
    PurgeOldTasksJob.perform_now

    refute AiTask.where(prompt: "old").exists?, "tasks past the default cutoff are dropped"
    assert AiTask.where(prompt: "fresh").exists?, "tasks within the cutoff stay"
    assert AiTask.where(prompt: "live").exists?,  "in-flight tasks are never touched"
  end

  test "accepts an explicit duration to widen the cutoff" do
    PurgeOldTasksJob.perform_now(older_than: 12.hours)

    refute AiTask.where(prompt: "old").exists?
    refute AiTask.where(prompt: "fresh").exists?, "12h cutoff catches the 1-day-old task too"
    assert AiTask.where(prompt: "live").exists?
  end

  test "runs on the maintenance queue" do
    assert_equal "maintenance", PurgeOldTasksJob.new.queue_name
  end
end
