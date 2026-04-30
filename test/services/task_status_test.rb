require "test_helper"

class TaskStatusTest < ActiveSupport::TestCase
  # In-memory test double that mimics SolidQueue::Job's interface narrowly
  # enough for TaskStatus. Avoids touching the queue DB (and its writes)
  # in unit tests — the real wiring is covered by integration tests.
  class FakeSqJob
    attr_reader :scheduled_at, :arguments
    attr_accessor :discarded

    def initialize(claimed: false, ready: false, scheduled: false, failed: false,
                   scheduled_at: nil, executions: 0)
      @claimed, @ready, @scheduled, @failed = claimed, ready, scheduled, failed
      @scheduled_at = scheduled_at
      @arguments = { "executions" => executions }
      @discarded = false
    end

    def claimed?   = @claimed
    def ready?     = @ready
    def scheduled? = @scheduled
    def failed?    = @failed
    def discard
      @discarded = true
    end
  end

  class FakeJobClass
    def initialize(records: {}); @records = records; end

    def where(active_job_id:)
      Relation.new(@records[active_job_id] || [])
    end

    Relation = Struct.new(:rows) do
      def order(*); self; end
      def first; rows.first; end
    end
  end

  def task(extras = {})
    AiTask.new({ repo_path: "/tmp/r", prompt: "p", active_job_id: "uuid-1" }.merge(extras))
  end

  test "terminal outcomes short-circuit to their label" do
    %i[done failed cancelled needs_review blocked].each do |o|
      status = TaskStatus.new(task(outcome: o.to_s), sq_job_class: FakeJobClass.new)
      assert_equal o, status.label
    end
  end

  test "in-flight with no SQ job falls back to :queued" do
    status = TaskStatus.new(task, sq_job_class: FakeJobClass.new)
    assert_equal :queued, status.label
  end

  test "in-flight + claimed SQ job -> :running and not cancellable" do
    sq = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(claimed: true) ] })
    status = TaskStatus.new(task, sq_job_class: sq)
    assert_equal :running, status.label
    refute status.cancellable?
  end

  test "in-flight + scheduled SQ job with executions=0 -> :queued" do
    sq = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(scheduled: true, executions: 0) ] })
    assert_equal :queued, TaskStatus.new(task, sq_job_class: sq).label
  end

  test "in-flight + scheduled SQ job with executions>=1 -> :retrying" do
    when_to_retry = 30.minutes.from_now
    job = FakeSqJob.new(scheduled: true, executions: 1, scheduled_at: when_to_retry)
    sq  = FakeJobClass.new(records: { "uuid-1" => [ job ] })
    status = TaskStatus.new(task, sq_job_class: sq)

    assert_equal :retrying, status.label
    assert_equal 2,         status.attempts, "attempts is executions + 1 (the upcoming run)"
    assert_in_delta when_to_retry.to_f, status.next_retry_at.to_f, 1
  end

  test "in-flight + failed SQ job (terminal at SQ level) -> :failed label" do
    sq = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(failed: true) ] })
    assert_equal :failed, TaskStatus.new(task, sq_job_class: sq).label
  end

  test "discard_queued_job discards a non-claimed job" do
    job = FakeSqJob.new(scheduled: true)
    sq  = FakeJobClass.new(records: { "uuid-1" => [ job ] })
    TaskStatus.new(task, sq_job_class: sq).discard_queued_job
    assert job.discarded
  end

  test "discard_queued_job refuses to discard a claimed (running) job" do
    job = FakeSqJob.new(claimed: true)
    sq  = FakeJobClass.new(records: { "uuid-1" => [ job ] })
    TaskStatus.new(task, sq_job_class: sq).discard_queued_job
    refute job.discarded, "must not discard a job currently being executed"
  end

  test "cancellable? matches in_flight && not running" do
    queued = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(scheduled: true) ] })
    assert TaskStatus.new(task, sq_job_class: queued).cancellable?

    running = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(claimed: true) ] })
    refute TaskStatus.new(task, sq_job_class: running).cancellable?

    done = TaskStatus.new(task(outcome: "done"), sq_job_class: FakeJobClass.new)
    refute done.cancellable?
  end

  test "next_retry_at is nil unless label is :retrying" do
    sq = FakeJobClass.new(records: { "uuid-1" => [ FakeSqJob.new(scheduled: true, scheduled_at: 1.hour.from_now) ] })
    assert_nil TaskStatus.new(task, sq_job_class: sq).next_retry_at, "scheduled but not retrying => no retry display"
  end

  test "retryable? is true for terminal outcomes other than cancelled" do
    %i[done failed needs_review blocked].each do |o|
      status = TaskStatus.new(task(outcome: o.to_s), sq_job_class: FakeJobClass.new)
      assert status.retryable?, "#{o} should offer retry"
    end
  end

  test "retryable? is false for cancelled and in-flight tasks" do
    cancelled = TaskStatus.new(task(outcome: "cancelled"), sq_job_class: FakeJobClass.new)
    refute cancelled.retryable?, "cancelled tasks must not surface a Retry button"

    in_flight = TaskStatus.new(task, sq_job_class: FakeJobClass.new)
    refute in_flight.retryable?, "in-flight tasks must not surface a Retry button"
  end
end
