require "test_helper"

class SuccessDetectorTest < ActiveSupport::TestCase
  test "returns nil when no sentinel is seen" do
    d = SuccessDetector.new
    [ "hello\n", "still working\n", "ORCH RESULT no colon\n" ].each { |l| d.consume(l) }
    assert_nil d.result
  end

  test "detects SUCCESS regardless of surrounding whitespace" do
    d = SuccessDetector.new
    d.consume("   ORCH_RESULT:  SUCCESS   \n")
    assert d.result.success?
  end

  test "detects BLOCKED with reason" do
    d = SuccessDetector.new
    d.consume("ORCH_RESULT: BLOCKED: tests are red\n")
    assert d.result.blocked?
    assert_equal "tests are red", d.result.reason
  end

  test "BLOCKED without explicit reason gets a placeholder" do
    d = SuccessDetector.new
    d.consume("ORCH_RESULT: BLOCKED\n")
    assert d.result.blocked?
    assert_equal "no reason given", d.result.reason
  end

  test "later sentinel overrides earlier one" do
    d = SuccessDetector.new
    d.consume("ORCH_RESULT: SUCCESS\n")
    d.consume("actually wait, ORCH_RESULT: BLOCKED: oops\n")
    assert d.result.blocked?
  end

  test "case-insensitive match" do
    d = SuccessDetector.new
    d.consume("orch_result: success\n")
    assert d.result.success?
  end
end
