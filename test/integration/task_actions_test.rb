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
    assert_equal "failed", task.outcome

    assert_enqueued_with(job: RunClaudeJob) do
      post retry_task_path(task)
    end
    task.reload
    assert_equal "in_flight", task.outcome
    assert_nil task.error
    assert_nil task.started_at
    assert_nil task.finished_at
    assert_redirected_to task_path(task)
  end

  test "cancel sets in-flight queued task to cancelled" do
    task = AiTask.create!(repo_path: @repo, prompt: "cancel me")
    post cancel_task_path(task)
    task.reload
    assert_equal "cancelled", task.outcome
    assert_redirected_to task_path(task)
  end

  test "cancel is a no-op once a task has reached a terminal outcome" do
    task = AiTask.create!(repo_path: @repo, prompt: "go")
    task.mark_done!(now: Time.current)
    post cancel_task_path(task)
    task.reload
    assert_equal "done", task.outcome
  end

  test "destroy deletes a finished task and its log, and redirects to the index" do
    task = AiTask.create!(repo_path: @repo, prompt: "delete me",
                          outcome: AiTask::DONE, finished_at: Time.current)
    log = Rails.root.join("tmp", "destroy-#{task.id}.log")
    File.write(log, "...")
    task.update!(log_path: log.to_s)

    delete task_path(task)

    assert_redirected_to tasks_path
    refute AiTask.exists?(task.id)
    refute File.exist?(log), "log file should be cleaned up"
  end

  test "bulk_destroy deletes the checked tasks and reports the count" do
    a = AiTask.create!(repo_path: @repo, prompt: "a", outcome: AiTask::DONE,   finished_at: Time.current)
    b = AiTask.create!(repo_path: @repo, prompt: "b", outcome: AiTask::FAILED, finished_at: Time.current)
    c = AiTask.create!(repo_path: @repo, prompt: "c", outcome: AiTask::DONE,   finished_at: Time.current)

    post bulk_destroy_tasks_path, params: { ids: [ a.id, b.id ] }

    assert_redirected_to tasks_path
    assert_match(/deleted 2 task/i, flash[:notice])
    refute AiTask.exists?(a.id)
    refute AiTask.exists?(b.id)
    assert AiTask.exists?(c.id)
  end

  test "bulk_destroy with no ids is a no-op" do
    a = AiTask.create!(repo_path: @repo, prompt: "a", outcome: AiTask::DONE, finished_at: Time.current)

    post bulk_destroy_tasks_path

    assert_redirected_to tasks_path
    assert AiTask.exists?(a.id), "row must survive an empty bulk delete"
  end

  test "purge sweeps old terminal tasks and reports the count" do
    old   = AiTask.create!(repo_path: @repo, prompt: "old",   outcome: AiTask::DONE, finished_at: 60.days.ago)
    fresh = AiTask.create!(repo_path: @repo, prompt: "fresh", outcome: AiTask::DONE, finished_at: 1.day.ago)

    post purge_tasks_path

    assert_redirected_to tasks_path
    assert_match(/purged 1 task/i, flash[:notice])
    refute AiTask.exists?(old.id)
    assert AiTask.exists?(fresh.id)
  end

  test "Mission Control engine is mounted at /jobs" do
    get "/jobs"
    # MC may require auth (401), redirect (302), or serve (200) — any proves the mount works.
    # A 404 would mean it's not mounted.
    refute_equal 404, response.status
  end
end
