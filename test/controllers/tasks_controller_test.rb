require "test_helper"

# Action-by-action unit tests covering controller-only concerns:
# strong-params filtering, 404s, validation rendering. Happy-path
# end-to-end is covered by integration + system tests.
class TasksControllerTest < ActionDispatch::IntegrationTest
  setup { @repo = Dir.mktmpdir("orch-ctrl-") }
  teardown { FileUtils.remove_entry(@repo) if File.exist?(@repo) }

  test "show 404s for unknown id" do
    get task_path("nope")
    assert_response :not_found
  end

  test "create with invalid params re-renders new" do
    post tasks_path, params: { ai_task: { repo_path: "", prompt: "" } }
    assert_response :unprocessable_entity
  end

  test "create permits only the documented attributes" do
    post tasks_path, params: { ai_task: {
      repo_path:  @repo, prompt: "x",
      outcome:    "done",       # forbidden — must default to in_flight
      log_path:   "/etc/passwd" # forbidden — runner controls log paths
    } }

    task = AiTask.last
    assert_equal AiTask::IN_FLIGHT, task.outcome
    assert_nil task.log_path
  end

  test "log returns plain-text body" do
    task = AiTask.create!(repo_path: @repo, prompt: "x")
    get log_task_path(task)
    assert_equal "text/plain", response.media_type
    assert_match "(no log yet)", response.body
  end

  test "index limits to 100 most-recent" do
    101.times { AiTask.create!(repo_path: @repo, prompt: "x") }
    get tasks_path
    assert_response :success
    # one <tr> per task in the body, plus 1 thead row
    rows = response.body.scan(/<tr/).size
    assert_equal 101, rows
  end
end
