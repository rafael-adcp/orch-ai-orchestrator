require "test_helper"

# Slice E: view log, retry, cancel actions + Mission Control mount.
class TaskActionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @repo = Dir.mktmpdir
    FileUtils.mkdir_p(Rails.root.join("log", "tasks"))
    @fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "output line\n" ], exit: 0 } })
    ClaudeRunner.subprocess_override = @fake
  end

  teardown do
    ClaudeRunner.subprocess_override = nil
    FileUtils.remove_entry(@repo) if File.directory?(@repo)
    AiTask.pluck(:log_path).compact.each { |p| FileUtils.rm_f(p) }
  end

  test "view log returns plain text log content" do
    task = AiTask.create!(repo_path: @repo, prompt: "go")
    task.enqueue!
    perform_enqueued_jobs

    get log_task_path(task)
    assert_response :success
    assert_match(/output line/, response.body)
  end

  test "view log before run returns no-log message" do
    task = AiTask.create!(repo_path: @repo, prompt: "go")
    get log_task_path(task)
    assert_response :success
    assert_match(/no log yet/, response.body)
  end

  test "retry resets failed task and re-enqueues" do
    fail_fake = FakeClaude.new(scripts: { /.*/ => { lines: [], exit: 1 } })
    ClaudeRunner.subprocess_override = fail_fake

    task = AiTask.create!(repo_path: @repo, prompt: "fail")
    task.enqueue!
    perform_enqueued_jobs
    task.reload
    assert_equal "failed", task.status

    assert_enqueued_with(job: RunClaudeJob) do
      post retry_task_path(task)
    end
    task.reload
    assert_equal "pending", task.status
    assert_nil task.error
    assert_nil task.started_at
    assert_nil task.finished_at
    assert_redirected_to task_path(task)
  end

  test "cancel sets pending task to cancelled" do
    task = AiTask.create!(repo_path: @repo, prompt: "cancel me")
    post cancel_task_path(task)
    task.reload
    assert_equal "cancelled", task.status
    assert_redirected_to task_path(task)
  end

  test "cancel does nothing if task is not pending" do
    task = AiTask.create!(repo_path: @repo, prompt: "go", status: "running")
    post cancel_task_path(task)
    task.reload
    assert_equal "running", task.status
  end

  test "Mission Control engine is mounted at /jobs" do
    get "/jobs"
    # MC may require auth (401), redirect (302), or serve (200) — any proves the mount works.
    # A 404 would mean it's not mounted.
    refute_equal 404, response.status
  end
end
