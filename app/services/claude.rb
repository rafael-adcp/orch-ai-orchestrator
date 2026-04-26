module Claude
  class Error < StandardError; end
  class UsageLimitError < Error; end
  class TimeoutError    < Error; end
  class ExitError       < Error; end
end
