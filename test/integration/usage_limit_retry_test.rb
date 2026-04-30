require "test_helper"

# Slice C: usage-limit phrase in subprocess output ->
#   1) AiTask outcome stays in_flight (NOT failed),
#   2) Solid Queue re-enqueues the job via retry_on,
#   3) on the next attempt the runner finishes the work and the original
#      log is preserved across attempts.
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

  test "limit phrase keeps task in_flight and schedules a retry" do
    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "working...\n", "You've hit your limit\n" ], exit: 0 }
    })

    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "do work" } }
    task = AiTask.last
    assert_equal "in_flight", task.outcome

    perform_enqueued_jobs(only: RunClaudeJob)
    task.reload

    assert_equal "in_flight", task.outcome,
      "usage limit must NOT mutate AiTask outcome — Solid Queue owns the retry"
    assert_nil task.error
    assert_nil task.finished_at
    assert_enqueued_jobs 1, only: RunClaudeJob

    get log_task_path(task)
    assert_response :success
    assert_match(/You've hit your limit/, response.body)
    assert_match(/Solid Queue will retry/i, response.body)
  end

  test "second attempt actually runs after the cooldown and reaches done" do
    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
    })

    post tasks_path, params: { ai_task: { repo_path: @repo, prompt: "do work" } }
    task = AiTask.last

    perform_enqueued_jobs(only: RunClaudeJob)
    assert_equal "in_flight", task.reload.outcome

    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "doing the work\n", "ORCH_RESULT: SUCCESS\n" ], exit: 0 }
    })

    travel_to(31.minutes.from_now) do
      perform_enqueued_jobs(only: RunClaudeJob)
    end

    task.reload
    assert_equal "done", task.outcome

    log = File.read(task.log_path)
    assert_match(/You've hit your limit/, log,    "first attempt's stdout should survive into the retry log")
    assert_match(/doing the work/, log,           "second attempt's stdout should be appended")
    assert_match(/task completed successfully/, log)
  end

  test "each limit pattern is detected" do
    [ "usage limit reached", "You've hit your limit", "5-hour limit reached" ].each do |phrase|
      fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "#{phrase}\n" ], exit: 0 } })
      runner = ClaudeRunner.new(
        AiTask.create!(repo_path: @repo, prompt: "test #{phrase}"),
        subprocess: fake, clock: Time
      )
      assert_raises(Claude::UsageLimitError) { runner.call }
    end
  end
end
