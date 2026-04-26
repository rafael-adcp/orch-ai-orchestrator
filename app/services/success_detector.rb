# Detects the orchestrator's completion sentinel in a stream of subprocess
# output lines. The sentinel is appended to every prompt by ClaudeCommand;
# its presence (and kind) is the *only* signal we trust to mark a task as
# done. Without it, exit code 0 from `claude -p` is ambiguous (max-turns
# reached, clarifying question asked, no-op, etc.) and the task should
# land in :needs_review instead.
#
#   ORCH_RESULT: SUCCESS
#   ORCH_RESULT: BLOCKED: <one-line reason>
#
# Matching is permissive on whitespace and on the optional colon after
# BLOCKED so small formatting drift from the model doesn't cause silent
# failures. The last sentinel line wins (if Claude prints multiple).
class SuccessDetector
  Result = Struct.new(:kind, :reason, keyword_init: true) do
    def success? = kind == :success
    def blocked? = kind == :blocked
  end

  SUCCESS_RE = /\bORCH_RESULT:\s*SUCCESS\b/i
  BLOCKED_RE = /\bORCH_RESULT:\s*BLOCKED\b\s*:?\s*(.*)$/i

  def initialize
    @result = nil
  end

  # Feed every line through this. Returns the most recent result, if any.
  def consume(line)
    if (m = line.match(BLOCKED_RE))
      @result = Result.new(kind: :blocked, reason: m[1].to_s.strip.presence || "no reason given")
    elsif line.match?(SUCCESS_RE)
      @result = Result.new(kind: :success, reason: nil)
    end
    @result
  end

  def result = @result
end
