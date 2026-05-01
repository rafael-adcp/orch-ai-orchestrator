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

  test "parses reset_at from line with reset time and timezone" do
    freeze_at = Time.find_zone("America/Sao_Paulo").local(2026, 4, 30, 22, 8, 33).utc
    detector = LimitDetector.new(clock: Class.new { define_method(:current) { freeze_at } }.new)

    line = "You've hit your limit · resets 11:20pm (America/Sao_Paulo)\n"
    hit = detector.detect(line)

    assert_kind_of LimitDetector::Hit, hit
    assert_in_delta Time.find_zone("America/Sao_Paulo").local(2026, 4, 30, 23, 20, 0).utc,
                    hit.reset_at, 1
  end

  test "reset_at is nil when no reset time in line" do
    hit = @detector.detect("You've hit your limit\n")
    assert_kind_of LimitDetector::Hit, hit
    assert_nil hit.reset_at
  end

  test "parses bare-hour reset times (e.g. '6am') with no minutes" do
    freeze_at = Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 2, 0, 0).utc
    detector = LimitDetector.new(clock: Class.new { define_method(:current) { freeze_at } }.new)

    line = "You've hit your limit · resets 6am (America/Sao_Paulo)\n"
    hit = detector.detect(line)

    assert_in_delta Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 6, 0, 0).utc,
                    hit.reset_at, 1
  end

  test "handles 12am (midnight) and 12pm (noon) without minutes" do
    freeze_at = Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 9, 0, 0).utc
    detector = LimitDetector.new(clock: Class.new { define_method(:current) { freeze_at } }.new)

    noon_hit = detector.detect("You've hit your limit · resets 12pm (America/Sao_Paulo)\n")
    assert_in_delta Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 12, 0, 0).utc,
                    noon_hit.reset_at, 1

    midnight_hit = detector.detect("You've hit your limit · resets 12am (America/Sao_Paulo)\n")
    assert_in_delta Time.find_zone("America/Sao_Paulo").local(2026, 5, 2, 0, 0, 0).utc,
                    midnight_hit.reset_at, 1
  end

  test "rolls to next day if reset time is already past" do
    # 11:25pm SP time, reset says 11:20pm — already passed, should be tomorrow
    freeze_at = Time.find_zone("America/Sao_Paulo").local(2026, 4, 30, 23, 25, 0).utc
    detector = LimitDetector.new(clock: Class.new { define_method(:current) { freeze_at } }.new)

    line = "You've hit your limit · resets 11:20pm (America/Sao_Paulo)\n"
    hit = detector.detect(line)

    assert_in_delta Time.find_zone("America/Sao_Paulo").local(2026, 5, 1, 23, 20, 0).utc,
                    hit.reset_at, 1
  end
end
