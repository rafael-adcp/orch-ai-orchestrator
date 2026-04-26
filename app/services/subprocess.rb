# Wraps IO.popen for streaming a child process line-by-line.
# This is the seam the runner depends on; tests inject a fake.
class Subprocess
  Result = Struct.new(:exit_status, keyword_init: true)

  # Sentinel for processes terminated by signal (no exit code). 128 mirrors
  # the shell convention of 128 + signal number; the precise value doesn't
  # matter, only that it is non-zero so finalize() routes to mark_failed!.
  SIGNAL_TERMINATED = 128

  def run(argv, cwd:, on_line:)
    status = nil
    Dir.chdir(cwd) do
      IO.popen(argv, err: %i[child out]) do |io|
        io.each_line { |line| on_line.call(line) }
      end
      status = $?.exitstatus || SIGNAL_TERMINATED
    end
    Result.new(exit_status: status)
  end
end
