require "test_helper"

# End-to-end recovery flow: a task fails on first run, the user retries it
# via the controller, the runner re-executes against a now-healthy
# subprocess, and the task lands in `done`.
class FailedRetrySucceedsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @repo = Dir.mktmpdir
    FileUtils.mkdir_p(Rails.root.join("log", "tasks"))
  end

  teardown do
    ClaudeRunner.subprocess_override = nil
    FileUtils.remove_entry(@repo) if File.directory?(@repo)
    AiTask.pluck(:log_path).compact.each { |p| FileUtils.rm_f(p) }
  end

  test "failed task can be retried via UI and succeeds on the second run" do
    # First run: subprocess exits non-zero -> task marked failed.
    ClaudeRunner.subprocess_override =
      FakeClaude.new(scripts: { /.*/ => { lines: [ "boom\n" ], exit: 1 } })

    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "flaky job" } }
    task = AiTask.last
    perform_enqueued_jobs(only: RunClaudeJob)

    task.reload
    assert_equal AiTask::FAILED, task.status
    assert_match(/exit code 1/, task.error)

    # User clicks Retry on the show page.
    get task_path(task)
    assert_response :success
    assert_match(/Retry/, response.body)

    # Swap in a healthy subprocess for the second attempt.
    ClaudeRunner.subprocess_override =
      FakeClaude.new(scripts: { /.*/ => { lines: [ "all good\n" ], exit: 0 } })

    post retry_task_path(task)
    assert_redirected_to task_path(task)

    task.reload
    assert_equal AiTask::PENDING, task.status
    assert_nil task.error
    assert_nil task.started_at
    assert_nil task.finished_at

    perform_enqueued_jobs(only: RunClaudeJob)

    task.reload
    assert_equal AiTask::DONE, task.status
    assert_nil task.error
    assert_predicate task.finished_at, :present?
    assert_match(/all good/, File.read(task.log_path))
  end
end
