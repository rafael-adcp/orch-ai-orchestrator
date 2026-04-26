require "shellwords"

# Builds the argv to invoke the `claude` CLI for a given task.
class ClaudeCommand
  DEFAULT_MODEL = "sonnet".freeze

  def initialize(bin: ENV.fetch("ORCH_CLAUDE_BIN", "claude"),
                 flags: ENV.fetch("ORCH_CLAUDE_FLAGS", "-p --permission-mode acceptEdits").split,
                 model: ENV["ORCH_CLAUDE_MODEL"].presence || DEFAULT_MODEL,
                 max_turns: ENV.fetch("ORCH_CLAUDE_MAX_TURNS", "30").to_i)
    @bin, @flags, @model, @max_turns = resolve_bin(bin), flags, model, max_turns
  end

  def build(task)
    cmd = [ @bin, *@flags, "--model", task.model.presence || @model,
            "--max-turns", @max_turns.to_s, task.prompt ]
    return cmd unless task.docker_cmd.present?
    [ *task.docker_cmd.split, cmd.shelljoin ]
  end

  private

  # On Windows, `CreateProcess` (used by Ruby's IO.popen array form) does not
  # honor PATHEXT or App Paths shims the way cmd.exe does. A bare `claude`
  # therefore fails with ENOENT even when `claude.exe` is on PATH. Resolve
  # the executable up-front so the spawn always sees an absolute path.
  def resolve_bin(bin)
    return bin if bin.include?(File::SEPARATOR) || bin.include?("/")
    return bin unless Gem.win_platform?

    exts = (ENV["PATHEXT"] || ".COM;.EXE;.BAT;.CMD").split(";").map(&:downcase)
    has_ext = exts.include?(File.extname(bin).downcase)
    candidates = has_ext ? [ bin ] : exts.map { |e| "#{bin}#{e}" }

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?
      candidates.each do |name|
        full = File.join(dir, name)
        return full if File.file?(full)
      end
    end
    bin
  end
end
