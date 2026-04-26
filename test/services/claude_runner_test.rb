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

  test "success sets status done and writes log" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "hello\n" ], exit: 0 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)
    runner.call

    @task.reload
    assert_equal "done", @task.status
    assert_predicate @task.started_at, :present?
    assert_predicate @task.finished_at, :present?
    assert_predicate @task.log_path, :present?
    assert File.read(@task.log_path).include?("hello")
  end

  test "non-zero exit sets status failed with error" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "oops\n" ], exit: 1 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)
    runner.call

    @task.reload
    assert_equal "failed", @task.status
    assert_match(/exit code 1/, @task.error)
  end

  test "usage limit phrase sets failed and raises UsageLimitError" do
    fake = FakeClaude.new(scripts: {
      /.*/ => { lines: [ "You've hit your limit\n" ], exit: 0 }
    })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)

    assert_raises(Claude::UsageLimitError) { runner.call }
    @task.reload
    assert_equal "failed", @task.status
    assert_match(/usage limit hit/, @task.error)
  end

  test "passes correct argv and cwd to subprocess" do
    builder = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 5)
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [], exit: 0 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, command_builder: builder, clock: @clock)
    runner.call

    call = fake.calls.first
    assert_equal @repo, call[:cwd]
    # Bin may be resolved to an absolute path on Windows.
    assert_match(/(?:\A|[\/\\])claude(?:\.exe|\.cmd|\.bat)?\z/i, call[:argv].first)
    assert_includes call[:argv], "do thing"
  end

  test "log file contains header and streamed lines" do
    fake = FakeClaude.new(scripts: { /.*/ => { lines: [ "line 1\n", "line 2\n" ], exit: 0 } })
    runner = ClaudeRunner.new(@task, subprocess: fake, clock: @clock)
    runner.call

    content = File.read(@task.reload.log_path)
    assert_match(/===== task #{@task.id} =====/, content)
    assert content.include?("line 1")
    assert content.include?("line 2")
  end

  test "unexpected error marks task failed and re-raises" do
    boom = Class.new do
      def run(_argv, cwd:, on_line:)
        raise RuntimeError, "boom from subprocess"
      end
    end.new
    runner = ClaudeRunner.new(@task, subprocess: boom, clock: @clock)

    err = assert_raises(RuntimeError) { runner.call }
    assert_equal "boom from subprocess", err.message

    @task.reload
    assert_equal "failed", @task.status
    assert_match(/unexpected error: RuntimeError: boom from subprocess/, @task.error)
    assert_predicate @task.finished_at, :present?
  end

  test "log writer write error marks task failed instead of orphaning in running" do
    failing_logs = Class.new do
      def path_for(id) = "/nope/#{id}.log"
      def write_header(path, _) = raise(LogWriter::WriteError, "cannot write log header to #{path}: denied")
      def append(*) = nil
    end.new
    runner = ClaudeRunner.new(@task, subprocess: FakeClaude.new, log_writer: failing_logs, clock: @clock)

    assert_raises(LogWriter::WriteError) { runner.call }

    @task.reload
    assert_equal "failed", @task.status
    assert_match(/LogWriter::WriteError/, @task.error)
  end

  private

  def log_path
    @log_dir.join("#{@task.id}.log").to_s
  end
end
