require "test_helper"

class ClaudeRunnerTest < ActiveSupport::TestCase
  FrozenClock = Struct.new(:current)

  setup do
    @repo = Dir.mktmpdir
    @task = AiTask.create!(repo_path: @repo, prompt: "do thing")
    @clock = FrozenClock.new(Time.current)
    @log_dir = Rails.root.join("log", "tasks")
    FileUtils.mkdir_p(@log_dir)
  end

  teardown do
    FileUtils.remove_entry(@repo) if File.directory?(@repo)
    FileUtils.rm_f(log_path)
  end

  test "success sets outcome=done and writes log" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "hello\n", "ORCH_RESULT: SUCCESS\n" ], exit: 0 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)
    runner.call

    @task.reload
    assert_equal "done", @task.outcome
    assert_predicate @task.started_at, :present?
    assert_predicate @task.finished_at, :present?
    assert_predicate @task.log_path, :present?
    assert File.read(@task.log_path).include?("hello")
  end

  test "non-zero exit sets outcome=failed with error" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "oops\n" ], exit: 1 } })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    @task.reload
    assert_equal "failed", @task.outcome
    assert_match(/exit code 1/, @task.error)
  end

  test "usage limit phrase leaves task in_flight and raises UsageLimitError" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
    })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)

    assert_raises(Claude::UsageLimitError) { runner.call }
    @task.reload
    assert_equal "in_flight", @task.outcome,
      "usage limit must NOT mutate the AiTask outcome — Solid Queue owns the retry"
    assert_nil @task.error
    assert_nil @task.finished_at
  end

  test "second attempt after a usage limit appends to the same log and reaches done" do
    first  = FakeClaude.new(scripts: { /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 } })
    second = FakeClaude.new(scripts: { /.*/ => { lines: [ "ORCH_RESULT: SUCCESS\n" ],   exit: 0 } })

    assert_raises(Claude::UsageLimitError) { ClaudeRunner.new(@task, subprocess: first,  clock: @clock).call }
    assert_equal "in_flight", @task.reload.outcome

    ClaudeRunner.new(@task, subprocess: second, clock: @clock).call
    assert_equal "done", @task.reload.outcome

    log = File.read(@task.log_path)
    assert_match(/You've hit your limit/, log,             "first attempt's stdout must survive")
    assert_match(/Solid Queue will retry/i, log)
    assert_match(/starting work on task/, log)
    assert_match(/task completed successfully/, log)
  end

  test "passes correct argv and cwd to subprocess" do
    builder = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 5, sentinel: false)
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [], exit: 0 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, command_builder: builder, clock: @clock)
    runner.call

    call = fake.calls.first
    assert_equal @repo, call[:cwd]
    assert_match(/(?:\A|[\/\\])claude(?:\.exe|\.cmd|\.bat)?\z/i, call[:argv].first)
    assert_includes call[:argv], "do thing"
  end

  test "log file contains start event, streamed lines, and completion event" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "line 1\n", "line 2\n", "ORCH_RESULT: SUCCESS\n" ], exit: 0 } })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    content = File.read(@task.reload.log_path)
    assert_match(/starting work on task #{@task.id}/, content)
    assert_match(/task completed successfully/, content)
    assert content.include?("line 1")
    assert content.include?("line 2")
    assert_match(/\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\]/, content)
  end

  test "unexpected error marks task failed and re-raises" do
    boom = Class.new do
      def run(_argv, cwd:, on_line:); raise RuntimeError, "boom from subprocess"; end
    end.new
    runner = ClaudeRunner.new(@task, subprocess: boom, clock: @clock)

    err = assert_raises(RuntimeError) { runner.call }
    assert_equal "boom from subprocess", err.message

    @task.reload
    assert_equal "failed", @task.outcome
    assert_match(/unexpected error: RuntimeError: boom from subprocess/, @task.error)
    assert_predicate @task.finished_at, :present?
  end

  test "log writer write error marks task failed instead of orphaning it in_flight" do
    failing_logs = Class.new do
      def path_for(id) = "/nope/#{id}.log"
      def event(path, _) = raise(LogWriter::WriteError, "cannot append to log #{path}: denied")
      def append(*) = nil
    end.new
    runner = ClaudeRunner.new(@task, subprocess: FakeClaude.new, log_writer: failing_logs, clock: @clock)

    assert_raises(LogWriter::WriteError) { runner.call }

    @task.reload
    assert_equal "failed", @task.outcome
    assert_match(/LogWriter::WriteError/, @task.error)
  end

  test "exit 0 with no sentinel lands in needs_review" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "did some thinking\n" ], exit: 0 } })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    @task.reload
    assert_equal "needs_review", @task.outcome
    assert_match(/no completion sentinel/i, @task.error)
    assert_predicate @task.finished_at, :present?
  end

  test "BLOCKED sentinel sets outcome=blocked with reason (not failed)" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "tried things\n", "ORCH_RESULT: BLOCKED: missing test fixtures\n" ], exit: 0 }
    })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    @task.reload
    assert_equal "blocked", @task.outcome
    assert_match(/missing test fixtures/i, @task.error)
  end

  test "later sentinel wins if both kinds appear" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "ORCH_RESULT: SUCCESS\n", "wait, ORCH_RESULT: BLOCKED: tests fail\n" ], exit: 0 }
    })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    @task.reload
    assert_equal "blocked", @task.outcome
    assert_match(/tests fail/, @task.error)
  end

  test "non-zero exit beats sentinel (claude crashed after declaring success)" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "ORCH_RESULT: SUCCESS\n" ], exit: 1 }
    })
    ClaudeRunner.new(@task, subprocess: fake, clock: @clock).call

    @task.reload
    assert_equal "failed", @task.outcome
    assert_match(/exit code 1/, @task.error)
  end

  private

  def log_path
    @log_dir.join("#{@task.id}.log").to_s
  end
end
