require "application_system_test_case"
require "support/fake_claude"

# Browser-style end-to-end walk: visit form -> submit -> see in list -> open
# show page -> verify retry/cancel buttons appear conditionally on status.
# Uses rack_test (no real browser) so it runs cross-platform without driver setup.
class TaskWorkflowTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @repo = Dir.mktmpdir("orch-system-")
    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: { /.*/ => [ "ok\n" ] })
  end

  teardown do
    ClaudeRunner.subprocess_override = nil
    FileUtils.remove_entry(@repo) if File.exist?(@repo)
    AiTask.pluck(:log_path).compact.each { |p| FileUtils.rm_f(p) }
  end

  test "user submits a task and sees it on the list" do
    visit new_task_path
    fill_in "ai_task[repo_path]", with: @repo
    fill_in "ai_task[prompt]",    with: "implement endpoint"
    click_button "Queue"

    assert_current_path %r{/tasks/[a-f0-9]{12}}
    assert_text "implement endpoint"

    visit tasks_path
    assert_text "implement endpoint"
  end

  test "pending task shows Cancel button; cancelling moves it to cancelled" do
    task = AiTask.create!(repo_path: @repo, prompt: "p", status: AiTask::PENDING)

    visit task_path(task)
    assert_button "Cancel"
    refute_button "Retry"

    click_button "Cancel"
    assert_text AiTask::CANCELLED
  end

  test "failed task shows Retry button; retry moves it back to pending" do
    task = AiTask.create!(
      repo_path: @repo, prompt: "p",
      status: AiTask::FAILED, error: "boom"
    )

    visit task_path(task)
    assert_button "Retry"
    refute_button "Cancel"

    click_button "Retry"
    assert_text AiTask::PENDING
  end

  test "View log link returns the log contents" do
    task = AiTask.create!(repo_path: @repo, prompt: "p")
    File.write(Rails.root.join("tmp", "#{task.id}.log"), "hello log")
    task.update!(log_path: Rails.root.join("tmp", "#{task.id}.log").to_s)

    visit task_path(task)
    click_link "View log"

    assert_text "hello log"
  ensure
    FileUtils.rm_f(Rails.root.join("tmp", "#{task.id}.log")) if task
  end

  test "full lifecycle: submit through browser, worker runs, status flips to done, log is visible" do
    ClaudeRunner.subprocess_override = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "starting\n", "working...\n", "all done\n" ], exit: 0 }
    })

    visit new_task_path
    fill_in "ai_task[repo_path]", with: @repo
    fill_in "ai_task[prompt]",    with: "ship feature x"
    click_button "Queue"

    task = AiTask.last
    assert_equal "ship feature x", task.prompt
    assert_equal AiTask::PENDING, task.status

    perform_enqueued_jobs
    visit task_path(task)
    assert_text AiTask::DONE

    click_link "View log"
    assert_text "starting"
    assert_text "all done"
  end
end
