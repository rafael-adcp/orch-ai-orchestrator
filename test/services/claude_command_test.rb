require "test_helper"

class ClaudeCommandTest < ActiveSupport::TestCase
  def task(attrs = {})
    AiTask.new({ repo_path: "/tmp/r", prompt: "do x" }.merge(attrs))
  end

  test "builds plain claude argv with defaults" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 30)
    argv = cmd.build(task)
    # On Windows, resolve_bin must return an absolute claude.exe path; on
    # other platforms it stays as the bare "claude". The dedicated
    # resolve_bin tests below lock the Windows behavior in detail.
    expected_bin = Gem.win_platform? ? %r{[/\\]claude\.(?:exe|cmd|bat)\z}i : /\Aclaude\z/
    assert_match(expected_bin, argv.first)
    assert_equal [ "-p", "--model", "sonnet", "--effort", "max", "--max-turns", "30" ], argv[1..-2]
    # Last arg is the prompt with the sentinel footer appended.
    assert argv.last.start_with?("do x"), "prompt should be preserved at the start"
    assert_match(/ORCH_RESULT:\s*SUCCESS/, argv.last)
  end

  test "sentinel footer can be disabled" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1, sentinel: false)
    assert_equal "do x", cmd.build(task).last
  end

  test "effort defaults to max for sonnet" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1, sentinel: false)
    argv = cmd.build(task)
    assert_equal "max", argv[argv.index("--effort") + 1]
  end

  test "effort defaults to xhigh for opus" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1, sentinel: false)
    argv = cmd.build(task(model: "opus"))
    assert_equal "xhigh", argv[argv.index("--effort") + 1]
  end

  test "per-task effort overrides default" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1, sentinel: false)
    argv = cmd.build(task(effort: "low"))
    assert_equal "low", argv[argv.index("--effort") + 1]
  end

  test "task model overrides default model" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 5)
    argv = cmd.build(task(model: "opus"))
    assert_includes argv, "opus"
    refute_includes argv, "sonnet"
  end

  test "wraps inside docker_cmd when set" do
    cmd = ClaudeCommand.new(bin: "claude", flags: [ "-p" ], model: "sonnet", max_turns: 5, sentinel: false)
    argv = cmd.build(task(docker_cmd: "docker run --rm img"))
    assert_equal [ "docker", "run", "--rm", "img" ], argv.first(4)
    inner = argv.last
    assert_includes inner, "claude", "inner claude command should be shell-joined"
    assert_includes inner, Shellwords.shellescape("do x"), "prompt should appear in inner string (shell-escaped)"
  end

  # --- Regression: Windows bin resolution ----------------------------------
  # IO.popen(array) on Windows uses CreateProcess, which (unlike cmd.exe)
  # does NOT honor PATHEXT or App Paths shims. A bare "claude" therefore
  # fails with Errno::ENOENT even when claude.exe is on PATH. ClaudeCommand
  # works around this by resolving the bin to an absolute path at build time.
  # If anyone removes resolve_bin or weakens it, these tests must fail.

  test "resolve_bin: on Windows, bare bin name is resolved to an absolute path with PATHEXT extension" do
    Dir.mktmpdir do |dir|
      fake_exe = File.join(dir, "claude.exe")
      File.write(fake_exe, "")

      with_env("PATH" => dir, "PATHEXT" => ".EXE;.CMD;.BAT") do
        with_win_platform(true) do
          cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1)
          assert_equal fake_exe, cmd.build(task).first,
            "bare 'claude' must be resolved to the absolute claude.exe found on PATH"
        end
      end
    end
  end

  test "resolve_bin: on Windows, returns bare name unchanged when nothing matches on PATH" do
    Dir.mktmpdir do |empty|
      with_env("PATH" => empty, "PATHEXT" => ".EXE") do
        with_win_platform(true) do
          cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1)
          # Falls back to the input so the spawn fails with a clear ENOENT
          # instead of silently changing what gets executed.
          assert_equal "claude", cmd.build(task).first
        end
      end
    end
  end

  test "resolve_bin: absolute or path-containing bins are passed through untouched" do
    with_win_platform(true) do
      [ "C:/tools/claude.exe", "C:\\tools\\claude.exe", "./bin/claude" ].each do |path|
        cmd = ClaudeCommand.new(bin: path, flags: [], model: "sonnet", max_turns: 1)
        assert_equal path, cmd.build(task).first, "#{path} should pass through unchanged"
      end
    end
  end

  test "resolve_bin: skips empty PATH entries (e.g. ';;') and keeps searching" do
    Dir.mktmpdir do |dir|
      fake_exe = File.join(dir, "claude.exe")
      File.write(fake_exe, "")

      with_env("PATH" => "#{File::PATH_SEPARATOR}#{dir}", "PATHEXT" => ".EXE") do
        with_win_platform(true) do
          cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1)
          assert_equal fake_exe, cmd.build(task).first,
            "empty leading PATH entry must be skipped, not treated as cwd"
        end
      end
    end
  end

  test "resolve_bin: on non-Windows, bin is passed through untouched even with PATHEXT set" do
    with_env("PATHEXT" => ".EXE") do
      with_win_platform(false) do
        cmd = ClaudeCommand.new(bin: "claude", flags: [], model: "sonnet", max_turns: 1)
        assert_equal "claude", cmd.build(task).first
      end
    end
  end

  private

  def with_env(overrides)
    previous = {}
    overrides.each_key { |k| previous[k] = ENV[k] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def with_win_platform(value)
    original = Gem.method(:win_platform?)
    Gem.singleton_class.define_method(:win_platform?) { value }
    yield
  ensure
    Gem.singleton_class.define_method(:win_platform?, original)
  end
end
