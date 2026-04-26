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
end
