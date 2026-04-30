require "test_helper"

# Slice A: submit a task via the form -> row created, status pending,
# Solid Queue job enqueued. We don't run the runner yet; we just assert
# the job was enqueued for the right task id.
class SubmitTaskTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { Dir.mktmpdir { |d| @repo = d.dup } }
  teardown { FileUtils.remove_entry(@repo) if File.directory?(@repo) }

  test "POST /tasks creates a task and enqueues a RunClaudeJob" do
    assert_enqueued_with(job: RunClaudeJob) do
      post tasks_path, params: { ai_task: {
        repo_path: @repo,
        prompt: "say hi",
        priority: 1
      } }
    end

    follow_redirect!
    assert_response :success

    task = AiTask.last
    assert_equal "in_flight", task.outcome
    assert_equal @repo, task.repo_path
    assert_equal "say hi", task.prompt
    assert_match(/queued/i, response.body)
    assert_match(/#{Regexp.escape(task.id)}/, response.body)
  end

  test "GET /tasks/new renders the form" do
    get new_task_path
    assert_response :success
    assert_match(/repo_path/, response.body)
    assert_match(/prompt/, response.body)
  end

  test "GET / lists tasks" do
    AiTask.create!(repo_path: @repo, prompt: "earlier")
    get root_path
    assert_response :success
    assert_match(/earlier/, response.body)
  end
end
