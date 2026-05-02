require "test_helper"

class LogWriterTest < ActiveSupport::TestCase
  FrozenClock = Struct.new(:current)

  setup do
    @root = Dir.mktmpdir("log-writer-")
    @clock = FrozenClock.new(Time.utc(2026, 4, 30, 12, 0, 0))
    @writer = LogWriter.new(root: @root, clock: @clock)
  end

  teardown { FileUtils.remove_entry(@root) if File.directory?(@root) }

  test "path_for builds <root>/<id>.log" do
    assert_equal File.join(@root, "abc.log"), @writer.path_for("abc")
  end

  test "event prefixes UTC ISO8601 timestamp and newline" do
    path = @writer.path_for("t1")
    @writer.event(path, "starting work")
    assert_equal "[2026-04-30T12:00:00Z] starting work\n", File.read(path)
  end

  test "event appends to existing content (does not truncate)" do
    path = @writer.path_for("t2")
    @writer.event(path, "first attempt")
    @writer.event(path, "retry attempt")
    content = File.read(path)
    assert_match(/first attempt/, content)
    assert_match(/retry attempt/, content)
    assert_operator content.lines.count, :>=, 2
  end

  test "append concatenates raw chunks without timestamp" do
    path = @writer.path_for("t3")
    @writer.append(path, "a\n")
    @writer.append(path, "b\n")
    assert_equal "a\nb\n", File.read(path)
  end

  test "event mixes with raw append in order" do
    path = @writer.path_for("t4")
    @writer.event(path, "start")
    @writer.append(path, "stdout line\n")
    @writer.event(path, "done")
    lines = File.read(path).lines
    assert_match(/start/, lines[0])
    assert_equal "stdout line\n", lines[1]
    assert_match(/done/, lines[2])
  end

  test "append wraps system errors in WriteError" do
    err = assert_raises(LogWriter::WriteError) do
      @writer.append(File.join(@root, "missing-dir", "x.log"), "data")
    end
    assert_match(/cannot append to log/, err.message)
  end

  test "event creates the parent directory" do
    nested = File.join(@root, "nested", "x.log")
    @writer.event(nested, "hello")
    assert File.exist?(nested)
  end

  test "ensure_dir wraps mkdir failures in WriteError" do
    # Force mkdir_p to fail by making a parent path component a regular file.
    blocker = File.join(@root, "blocker")
    File.write(blocker, "")
    err = assert_raises(LogWriter::WriteError) do
      @writer.ensure_dir(File.join(blocker, "x.log"))
    end
    assert_match(/cannot create log directory/, err.message)
  end
end
