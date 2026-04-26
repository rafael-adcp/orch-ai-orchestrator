# Detects "usage limit" phrases in a stream of subprocess output lines.
# Encapsulates the patterns and the structured result so callers don't
# leak regex internals into error messages.
class LimitDetector
  Hit = Struct.new(:phrase, keyword_init: true) do
    def to_s = phrase
  end

  PATTERNS = [
    /usage limit reached/i,
    /you've hit your limit/i,
    /5-hour limit reached/i
  ].freeze

  def initialize(patterns: PATTERNS)
    @patterns = patterns
  end

  def detect(line)
    match = @patterns.find { |re| line.match?(re) }
    match && Hit.new(phrase: line.match(match)[0])
  end
end
