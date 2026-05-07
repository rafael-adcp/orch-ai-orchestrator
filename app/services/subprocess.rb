# Wraps IO.popen for streaming a child process line-by-line.
# This is the seam the runner depends on; tests inject a fake.
class Subprocess
  Result = Struct.new(:exit_status, keyword_init: true)

  # Sentinel for processes terminated by signal (no exit code). 128 mirrors
  # the shell convention of 128 + signal number; the precise value doesn't
  # matter, only that it is non-zero so finalize() routes to mark_failed!.
  SIGNAL_TERMINATED = 128

  # `chdir:` is a Process.spawn option that sets the *child's* cwd at spawn
  # time, leaving the parent's cwd untouched. Using Dir.chdir here would
  # mutate process-global state and collide across worker threads.
  def run(argv, cwd:, on_line:)
    IO.popen(argv, err: %i[child out], chdir: cwd) do |io|
      io.each_line { |line| on_line.call(line) }
    end
    Result.new(exit_status: $?.exitstatus || SIGNAL_TERMINATED)
  end
end
