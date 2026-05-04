require "test_helper"

class SubprocessTest < ActiveSupport::TestCase
  setup do
    @dir_a = File.realpath(Dir.mktmpdir)
    @dir_b = File.realpath(Dir.mktmpdir)
  end

  teardown do
    FileUtils.remove_entry(@dir_a) if @dir_a && File.directory?(@dir_a)
    FileUtils.remove_entry(@dir_b) if @dir_b && File.directory?(@dir_b)
  end

  test "runs argv in the requested cwd" do
    out = []
    result = Subprocess.new.run(
      [ "ruby", "-e", "STDOUT.puts Dir.pwd" ],
      cwd: @dir_a,
      on_line: ->(line) { out << line.chomp }
    )
    assert_equal 0, result.exit_status
    assert_includes out.map { |l| File.realpath(l) rescue l }, @dir_a
  end

  # Worker pool runs `threads: 3` per process, so two tasks for *different*
  # repos can land in two threads of the same Ruby process. `Dir.chdir` is
  # process-wide; concurrent calls collide with
  # `RuntimeError: conflicting chdir during another chdir block` and the
  # README's "many repos in parallel" guarantee silently breaks.
  test "concurrent runs in different cwds do not collide" do
    argv = [ "ruby", "-e", "STDOUT.puts Dir.pwd; STDOUT.flush; sleep 0.5" ]
    a_inside = Queue.new
    out_a = []
    out_b = []

    thread_a = Thread.new do
      Subprocess.new.run(argv, cwd: @dir_a, on_line: ->(line) {
        out_a << line.chomp
        a_inside << :ready
      })
    end
    a_inside.pop # guarantee A's chdir block is open before B starts

    thread_b = Thread.new do
      Subprocess.new.run(argv, cwd: @dir_b, on_line: ->(line) { out_b << line.chomp })
    end

    result_a = thread_a.value
    result_b = thread_b.value

    assert_equal 0, result_a.exit_status, "thread A failed"
    assert_equal 0, result_b.exit_status, "thread B failed"
    assert_includes out_a.map { |l| File.realpath(l) rescue l }, @dir_a
    assert_includes out_b.map { |l| File.realpath(l) rescue l }, @dir_b
  end
end
