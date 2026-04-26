# Wraps IO.popen for streaming a child process line-by-line.
# This is the seam the runner depends on; tests inject a fake.
class Subprocess
  Result = Struct.new(:exit_status, keyword_init: true)

  def run(argv, cwd:, on_line:)
    status = nil
    Dir.chdir(cwd) do
      IO.popen(argv, err: %i[child out]) do |io|
        io.each_line { |line| on_line.call(line) }
      end
      status = $?.exitstatus
    end
    Result.new(exit_status: status)
  end
end
