require "test_helper"

# Slice B: runner streams output, writes a log, and marks the task done.
# FakeClaude is injected at the class level so RunClaudeJob -> ClaudeRunner
# picks it up without any change to the job's perform signature.
class RunnerCompletesTaskTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @repo = Dir.mktmpdir
    @log_dir = Rails.root.join("log", "tasks")
    FileUtils.mkdir_p(@log_dir)

    @fake = FakeClaude.new(scripts: {
      /say hi/ => { lines: [ "hello from claude", "all done", "ORCH_RESULT: SUCCESS" ], exit: 0 }
    })
    ClaudeRunner.subprocess_override = @fake
  end

  teardown do
    ClaudeRunner.subprocess_override = nil
    FileUtils.remove_entry(@repo) if File.directory?(@repo)
    # clean up any log files this test created
    AiTask.pluck(:log_path).compact.each { |p| FileUtils.rm_f(p) }
  end

  test "job runs task to done, show page says done, log is readable" do
    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "say hi" } }
    task = AiTask.last

    perform_enqueued_jobs
    task.reload

    assert_equal "done", task.outcome
    assert_predicate task.started_at, :present?
    assert_predicate task.finished_at, :present?
    assert_predicate task.log_path, :present?

    get task_path(task)
    assert_response :success
    assert_match(/done/, response.body)

    get log_task_path(task)
    assert_response :success
    assert_match(/hello from claude/, response.body)
    assert_match(/all done/, response.body)
  end

  test "non-zero exit marks task failed with error message" do
    fail_fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "some output" ], exit: 2 }
    })
    ClaudeRunner.subprocess_override = fail_fake

    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "break stuff" } }
    task = AiTask.last

    perform_enqueued_jobs
    task.reload

    assert_equal "failed", task.outcome
    assert_match(/exit code 2/, task.error)

    get task_path(task)
    assert_response :success
    assert_match(/failed/, response.body)
  end
end
