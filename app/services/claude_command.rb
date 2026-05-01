require "shellwords"

# Builds the argv to invoke the `claude` CLI for a given task.
class ClaudeCommand
  DEFAULT_MODEL = "sonnet".freeze
  DEFAULT_EFFORT_BY_MODEL = { "opus" => "xhigh" }.freeze
  DEFAULT_EFFORT_FALLBACK = "max".freeze

  # Footer appended to every prompt so we can tell apart "Claude finished"
  # from "Claude exited 0 after stopping for any reason." The runner greps
  # the log for these markers; without one, the task lands in :needs_review
  # instead of :done. Disable by setting ORCH_SENTINEL=0 (not recommended).
  SENTINEL_FOOTER = <<~PROMPT.freeze

    ---
    When you finish, print exactly one line as the very last thing in your output:
      ORCH_RESULT: SUCCESS                       — if the task is fully complete
      ORCH_RESULT: BLOCKED: <one-line reason>    — if you stopped early or could not finish
    Do not omit this line. Do not wrap it in code fences. It must be on its own line.
  PROMPT

  def initialize(bin: Rails.application.config.orchestrator[:claude_bin],
                 flags: Rails.application.config.orchestrator[:claude_flags],
                 model: Rails.application.config.orchestrator[:claude_model],
                 max_turns: Rails.application.config.orchestrator[:claude_max_turns],
                 sentinel: Rails.application.config.orchestrator[:sentinel])
    @bin, @flags, @model, @max_turns, @sentinel =
      resolve_bin(bin), flags, model, max_turns, sentinel
  end

  def build(task)
    prompt = @sentinel ? "#{task.prompt}#{SENTINEL_FOOTER}" : task.prompt
    resolved_model = task.model.presence || @model
    resolved_effort = task.effort.presence || effort_default(resolved_model)
    cmd = [ @bin, *@flags, "--model", resolved_model,
            "--effort", resolved_effort,
            "--max-turns", @max_turns.to_s, prompt ]
    return cmd unless task.docker_cmd.present?
    [ *task.docker_cmd.split, cmd.shelljoin ]
  end

  private

  def effort_default(model)
    DEFAULT_EFFORT_BY_MODEL.fetch(model.to_s.downcase, DEFAULT_EFFORT_FALLBACK)
  end

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
