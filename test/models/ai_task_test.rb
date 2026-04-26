require "test_helper"

class AiTaskTest < ActiveSupport::TestCase
  def valid_attrs(extra = {})
    { repo_path: "/tmp/repo", prompt: "do thing" }.merge(extra)
  end

  test "valid with required attrs" do
    assert AiTask.new(valid_attrs).valid?
  end

  test "defaults provider to claude" do
    assert_equal "claude", AiTask.new(valid_attrs).provider
  end

  test "requires prompt and repo_path" do
    refute AiTask.new(prompt: "x").valid?
    refute AiTask.new(repo_path: "/x").valid?
  end

  test "rejects unknown status" do
    refute AiTask.new(valid_attrs(status: "weird")).valid?
  end

  test "rejects unknown provider" do
    refute AiTask.new(valid_attrs(provider: "copilot")).valid?
  end

  test "assigns short id on create" do
    t = AiTask.create!(valid_attrs)
    assert_equal 12, t.id.length
  end

  test "scopes filter by status" do
    AiTask.create!(valid_attrs(status: "pending"))
    AiTask.create!(valid_attrs(status: "running"))
    assert_equal 1, AiTask.pending.count
    assert_equal 1, AiTask.running.count
  end

  test "recent orders newest first" do
    a = AiTask.create!(valid_attrs)
    travel 2.seconds do
      b = AiTask.create!(valid_attrs)
      assert_equal [ b.id, a.id ], AiTask.recent.pluck(:id)
    end
  end

  # --- transition guards ---

  test "mark_running! only allowed from pending" do
    t = AiTask.create!(valid_attrs(status: AiTask::DONE))
    assert_raises(AiTask::InvalidTransition) { t.mark_running!(now: Time.current, log_path: "/x") }
  end

  test "mark_done! only allowed from running" do
    t = AiTask.create!(valid_attrs(status: AiTask::PENDING))
    assert_raises(AiTask::InvalidTransition) { t.mark_done!(now: Time.current) }
  end

  test "retry! only allowed from failed" do
    t = AiTask.create!(valid_attrs(status: AiTask::DONE))
    assert_raises(AiTask::InvalidTransition) { t.retry! }
  end

  test "cancel! is a no-op (returns false) when not pending" do
    t = AiTask.create!(valid_attrs(status: AiTask::DONE))
    refute t.cancel!
    assert_equal AiTask::DONE, t.reload.status
  end

  test "happy-path transitions: pending -> running -> done" do
    t = AiTask.create!(valid_attrs)
    t.mark_running!(now: Time.current, log_path: "/tmp/x.log")
    assert_equal AiTask::RUNNING, t.status
    t.mark_done!(now: Time.current)
    assert_equal AiTask::DONE, t.status
  end
end
