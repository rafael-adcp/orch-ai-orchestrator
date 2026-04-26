require "test_helper"

class LogWriterTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("log-writer-")
    @writer = LogWriter.new(root: @root)
  end

  teardown { FileUtils.remove_entry(@root) if File.directory?(@root) }

  test "path_for builds <root>/<id>.log" do
    assert_equal File.join(@root, "abc.log"), @writer.path_for("abc")
  end

  test "write_header creates the file with the given content" do
    path = @writer.path_for("t1")
    @writer.write_header(path, "header\n")
    assert_equal "header\n", File.read(path)
  end

  test "append concatenates chunks" do
    path = @writer.path_for("t2")
    @writer.write_header(path, "h\n")
    @writer.append(path, "a\n")
    @writer.append(path, "b\n")
    assert_equal "h\na\nb\n", File.read(path)
  end

  test "write_header wraps system errors in WriteError" do
    # Path under a regular file (not a directory) -> ENOTDIR / EEXIST.
    blocker = File.join(@root, "blocker")
    File.write(blocker, "x")
    bad_path = File.join(blocker, "child.log")

    err = assert_raises(LogWriter::WriteError) { @writer.write_header(bad_path, "h") }
    assert_match(/cannot write log header/, err.message)
  end

  test "append wraps system errors in WriteError" do
    err = assert_raises(LogWriter::WriteError) do
      @writer.append(File.join(@root, "missing-dir", "x.log"), "data")
    end
    assert_match(/cannot append to log/, err.message)
  end
end
