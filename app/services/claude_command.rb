require "shellwords"

# Builds the argv to invoke the `claude` CLI for a given task.
class ClaudeCommand
  def initialize(bin: ENV.fetch("ORCH_CLAUDE_BIN", "claude"),
                 flags: ENV.fetch("ORCH_CLAUDE_FLAGS", "-p --permission-mode acceptEdits").split,
                 model: ENV.fetch("ORCH_CLAUDE_MODEL", "sonnet"),
                 max_turns: ENV.fetch("ORCH_CLAUDE_MAX_TURNS", "30").to_i)
    @bin, @flags, @model, @max_turns = bin, flags, model, max_turns
  end

  def build(task)
    cmd = [ @bin, *@flags, "--model", task.model || @model,
            "--max-turns", @max_turns.to_s, task.prompt ]
    return cmd unless task.docker_cmd
    [ *task.docker_cmd.split, cmd.shelljoin ]
  end
end
