# Argv-driven fake for the Subprocess seam.
# Scripts: scripts is a hash of regex => Array<String> | { lines:, exit: }
# The first matching argv wins; default is exit 0 with no output.
class FakeClaude
  Result = Struct.new(:exit_status, keyword_init: true)

  attr_reader :calls

  def initialize(scripts: {}, default_exit: 0)
    @scripts = scripts
    @default_exit = default_exit
    @calls = []
  end

  def run(argv, cwd:, on_line:)
    @calls << { argv: argv, cwd: cwd }
    script = match(argv)
    Array(script[:lines]).each { |line| on_line.call(line.end_with?("\n") ? line : line + "\n") }
    Result.new(exit_status: script.fetch(:exit, @default_exit))
  end

  private

  def match(argv)
    joined = argv.join(" ")
    @scripts.each do |pattern, value|
      next unless pattern === joined
      return value.is_a?(Hash) ? value : { lines: value }
    end
    {}
  end
end
