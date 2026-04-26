require "test_helper"

# Slice C: usage-limit phrase in subprocess output -> task marked failed,
# and the job is re-enqueued for retry (via retry_on UsageLimitError).
class UsageLimitRetryTest < ActionDispatch::IntegrationTest
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

  test "limit phrase marks task failed and schedules a retry" do
    limit_fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "working...\n", "You've hit your limit\n" ], exit: 0 }
    })
    ClaudeRunner.subprocess_override = limit_fake

    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "do work" } }
    task = AiTask.last
    assert_equal "pending", task.status

    # Perform only the first attempt — it should raise UsageLimitError,
    # which retry_on catches and re-enqueues.
    perform_enqueued_jobs(only: RunClaudeJob)
    task.reload

    assert_equal "failed", task.status
    assert_match(/usage limit hit/, task.error)
    assert_predicate task.finished_at, :present?

    # The retry_on should have enqueued a new job for later execution
    assert_enqueued_jobs 1, only: RunClaudeJob

    # Show page reflects the failure
    get task_path(task)
    assert_response :success
    assert_match(/failed/, response.body)
    assert_match(/usage limit/, response.body)

    # Log file captured the limit phrase
    get log_task_path(task)
    assert_response :success
    assert_match(/You've hit your limit/, response.body)
  end

  test "each limit pattern is detected" do
    ["usage limit reached", "You've hit your limit", "5-hour limit reached"].each do |phrase|
      fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "#{phrase}\n" ], exit: 0 } })
      runner = ClaudeRunner.new(
        AiTask.create!(repo_path: @repo, prompt: "test #{phrase}"),
        subprocess: fake, clock: Time
      )
      assert_raises(Claude::UsageLimitError) { runner.call }
    end
  end
end
