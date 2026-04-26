require "test_helper"

class ClaudeCommandTest < ActiveSupport::TestCase
  def task(attrs = {})
    AiTask.new({ repo_path: "/tmp/r", prompt: "do x" }.merge(attrs))
  end

  test "builds plain claude argv with defaults" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 30)
    argv = cmd.build(task)
    # On Windows the bin is resolved to an absolute path (e.g. claude.exe);
    # elsewhere it stays as "claude". Match either form.
    assert_match(/(?:\A|[\/\\])claude(?:\.exe|\.cmd|\.bat)?\z/i, argv.first)
    assert_equal [ "-p", "--model", "sonnet", "--max-turns", "30", "do x" ], argv.drop(1)
  end

  test "task model overrides default model" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 5)
    argv = cmd.build(task(model: "opus"))
    assert_includes argv, "opus"
    refute_includes argv, "sonnet"
  end

  test "wraps inside docker_cmd when set" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 5)
    argv = cmd.build(task(docker_cmd: "docker run --rm img"))
    assert_equal [ "docker", "run", "--rm", "img" ], argv.first(4)
    inner = argv.last
    assert inner.include?("claude"), "inner claude command should be shell-joined"
    assert inner.include?(Shellwords.shellescape("do x")), "prompt should appear in inner string (shell-escaped)"
  end
end
