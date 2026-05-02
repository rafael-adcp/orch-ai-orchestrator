class LimitDetector
  Hit = Struct.new(:phrase, :reset_at, keyword_init: true) do
    def to_s = phrase
  end

  PATTERNS = [
    /usage limit reached/i,
    /you've hit your limit/i,
    /5-hour limit reached/i
  ].freeze

  # Claude prints either "11:20pm" or, on round hours, "6am". Minutes optional.
  RESET_PATTERN = /resets\s+(\d{1,2}(?::\d{2})?(?:am|pm))\s+\(([^)]+)\)/i
  HOUR_PATTERN  = /\A(\d{1,2})(?::(\d{2}))?(am|pm)\z/i

  def initialize(patterns: PATTERNS, clock: Time)
    @patterns = patterns
    @clock = clock
  end

  def detect(line)
    match = @patterns.find { |re| line.match?(re) }
    return nil unless match
    Hit.new(phrase: line.match(match)[0], reset_at: parse_reset_at(line))
  end

  private

  def parse_reset_at(line)
    m = line.match(RESET_PATTERN)
    return nil unless m
    tz = ActiveSupport::TimeZone[m[2]]
    compute_reset(tz, m[1])
  rescue
    nil
  end

  def compute_reset(tz, time_str)
    return nil unless tz
    h, min = to_24h(time_str)
    local = @clock.current.in_time_zone(tz)
    cand = tz.local(local.year, local.month, local.day, h, min, 0)
    cand <= local ? cand + 1.day : cand
  end

  # The outer RESET_PATTERN already constrained time_str to the same shape
  # HOUR_PATTERN matches, so the inner match is guaranteed. If the regexes
  # ever diverge, parse_reset_at's rescue catches the resulting NoMethodError.
  def to_24h(time_str)
    m = time_str.match(HOUR_PATTERN)
    h, min, mer = m[1].to_i, m[2].to_i, m[3].downcase
    [ normalize_hour(h, mer), min ]
  end

  def normalize_hour(h, mer)
    return 0  if mer == "am" && h == 12
    return 12 if mer == "pm" && h == 12
    mer == "pm" ? h + 12 : h
  end
end
