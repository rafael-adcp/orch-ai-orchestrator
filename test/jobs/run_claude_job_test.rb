require "test_helper"

class RunClaudeJobTest < ActiveSupport::TestCase
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

  test "retries on UsageLimitError" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
    })
    ClaudeRunner.subprocess_override = fake

    task = AiTask.create!(repo_path: @repo, prompt: "go")
    RunClaudeJob.perform_later(task.id)

    perform_enqueued_jobs(only: RunClaudeJob)
    assert_enqueued_jobs 1, only: RunClaudeJob
  end

  test "schedules retry at exact reset time when limit line includes it" do
    freeze_time do
      # Claude prints "resets 00:30am (UTC)" — 30 minutes from frozen now (00:00 UTC)
      reset_str = 30.minutes.from_now.strftime("%l:%M%P").strip
      line = "You've hit your limit · resets #{reset_str} (UTC)\n"
      ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
        /.*/ => { lines: [ line ], exit: 0 }
      })

      task = AiTask.create!(repo_path: @repo, prompt: "go")
      RunClaudeJob.perform_later(task.id)
      perform_enqueued_jobs(only: RunClaudeJob)

      enqueued = enqueued_jobs.find { |j| j[:job] == RunClaudeJob }
      assert enqueued, "expected a retry to be enqueued"
      # Tolerate up to 60s because strftime truncates seconds from the reset time
      assert_in_delta 30.minutes.from_now.to_f, enqueued[:at], 60
    end
  end

  test "schedules retry at exact reset time for bare-hour format (e.g. '6am')" do
    travel_to Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 2, 8, 53) do
      ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
        /.*/ => { lines: [ "You've hit your limit · resets 6am (America/Sao_Paulo)\n" ], exit: 0 }
      })

      task = AiTask.create!(repo_path: @repo, prompt: "go")
      RunClaudeJob.perform_later(task.id)
      perform_enqueued_jobs(only: RunClaudeJob)

      enqueued = enqueued_jobs.find { |j| j[:job] == RunClaudeJob }
      assert enqueued, "expected a retry to be enqueued"
      expected = Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 6, 0, 0).to_f
      assert_in_delta expected, enqueued[:at], 5
    end
  end

  test "falls back to 30-minute wait when no reset time in output" do
    freeze_time do
      ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
        /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
      })

      task = AiTask.create!(repo_path: @repo, prompt: "go")
      RunClaudeJob.perform_later(task.id)
      perform_enqueued_jobs(only: RunClaudeJob)

      enqueued = enqueued_jobs.find { |j| j[:job] == RunClaudeJob }
      assert enqueued, "expected a retry to be enqueued"
      assert_in_delta 30.minutes.from_now.to_f, enqueued[:at], 5
    end
  end

  test "stops retrying after MAX_LIMIT_RETRIES attempts" do
    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
    })

    task = AiTask.create!(repo_path: @repo, prompt: "go")

    job = RunClaudeJob.new(task.id)
    job.executions = Rails.application.config.orchestrator[:max_limit_retries]

    assert_raises(Claude::UsageLimitError) { job.perform(task.id) }
    assert_enqueued_jobs 0, only: RunClaudeJob
  end

  test "does not retry on plain failure" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [], exit: 1 }
    })
    ClaudeRunner.subprocess_override = fake

    task = AiTask.create!(repo_path: @repo, prompt: "go")
    RunClaudeJob.perform_later(task.id)

    perform_enqueued_jobs(only: RunClaudeJob)
    assert_enqueued_jobs 0, only: RunClaudeJob
  end

  test "discards when task not found" do
    RunClaudeJob.perform_later("nonexistent_id")
    assert_nothing_raised { perform_enqueued_jobs(only: RunClaudeJob) }
    assert_enqueued_jobs 0, only: RunClaudeJob
  end

  test "same repo_path produces same concurrency key" do
    a = AiTask.create!(repo_path: @repo, prompt: "first")
    b = AiTask.create!(repo_path: @repo, prompt: "second")
    key_a = RunClaudeJob.new(a.id).concurrency_key
    key_b = RunClaudeJob.new(b.id).concurrency_key
    assert_equal key_a, key_b, "tasks on the same repo must share a concurrency key"
  end

  test "different repo_path produces different concurrency key" do
    other_repo = Dir.mktmpdir
    a = AiTask.create!(repo_path: @repo, prompt: "first")
    b = AiTask.create!(repo_path: other_repo, prompt: "second")
    key_a = RunClaudeJob.new(a.id).concurrency_key
    key_b = RunClaudeJob.new(b.id).concurrency_key
    refute_equal key_a, key_b, "tasks on different repos must have different concurrency keys"
  ensure
    FileUtils.remove_entry(other_repo) if other_repo && File.directory?(other_repo)
  end

  test "concurrency limit is 1" do
    assert_equal 1, RunClaudeJob.concurrency_limit
  end

  # --- recurring ---

  test "schedules next run after completing a recurring task" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "ORCH_RESULT: SUCCESS\n" ], exit: 0 } })
    ClaudeRunner.subprocess_override = fake

    task = AiTask.create!(repo_path: @repo, prompt: "go", recurring_interval_hours: 6)
    RunClaudeJob.perform_later(task.id)
    perform_enqueued_jobs(only: RunClaudeJob)

    assert_enqueued_jobs 1, only: RunClaudeJob
    task.reload
    assert_equal AiTask::IN_FLIGHT, task.outcome
  end

  test "does not schedule next run for a one-shot task" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "ORCH_RESULT: SUCCESS\n" ], exit: 0 } })
    ClaudeRunner.subprocess_override = fake

    task = AiTask.create!(repo_path: @repo, prompt: "go")
    RunClaudeJob.perform_later(task.id)
    perform_enqueued_jobs(only: RunClaudeJob)

    assert_enqueued_jobs 0, only: RunClaudeJob
  end
end
