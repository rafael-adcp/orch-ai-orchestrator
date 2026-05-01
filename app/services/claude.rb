module Claude
  class Error < StandardError; end
  class UsageLimitError < Error
    attr_reader :reset_at

    def initialize(message = nil, reset_at: nil)
      super(message)
      @reset_at = reset_at
    end
  end
end
