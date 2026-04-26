require "test_helper"

class LimitDetectorTest < ActiveSupport::TestCase
  setup { @detector = LimitDetector.new }

  test "returns nil for unrelated lines" do
    assert_nil @detector.detect("compiling assets...\n")
  end

  test "detects each known phrase and returns a structured hit" do
    [
      "Usage limit reached",
      "You've hit your limit",
      "5-hour limit reached"
    ].each do |phrase|
      hit = @detector.detect("...prefix... #{phrase} ...suffix...\n")
      assert_kind_of LimitDetector::Hit, hit, "expected hit for #{phrase.inspect}"
      assert_match(/#{Regexp.escape(phrase)}/i, hit.phrase)
      assert_equal hit.phrase, hit.to_s
    end
  end

  test "patterns are injectable" do
    custom = LimitDetector.new(patterns: [/banana/])
    assert_nil custom.detect("usage limit reached\n")
    assert_kind_of LimitDetector::Hit, custom.detect("found banana\n")
  end
end
