require "test_helper"

class AiTaskTest < ActiveSupport::TestCase
  def valid_attrs(extra = {})
    { repo_path: "/tmp/repo", prompt: "do thing" }.merge(extra)
  end

  test "valid with required attrs" do
    assert AiTask.new(valid_attrs).valid?
  end

  test "defaults provider to claude and outcome to in_flight" do
    t = AiTask.new(valid_attrs)
    assert_equal "claude",    t.provider
    assert_equal "in_flight", t.outcome
  end

  test "requires prompt and repo_path" do
    refute AiTask.new(prompt: "x").valid?
    refute AiTask.new(repo_path: "/x").valid?
  end

  test "rejects unknown outcome" do
    refute AiTask.new(valid_attrs(outcome: "weird")).valid?
  end

  test "rejects unknown provider" do
    refute AiTask.new(valid_attrs(provider: "copilot")).valid?
  end

  test "assigns short id on create" do
    assert_equal 12, AiTask.create!(valid_attrs).id.length
  end

  test "in_flight scope returns only in-flight tasks" do
    AiTask.create!(valid_attrs)
    AiTask.create!(valid_attrs(outcome: AiTask::DONE))
    assert_equal 1, AiTask.in_flight.count
  end

  test "recent orders newest first" do
    a = AiTask.create!(valid_attrs)
    travel 2.seconds do
      b = AiTask.create!(valid_attrs)
      assert_equal [ b.id, a.id ], AiTask.recent.pluck(:id)
    end
  end

  # --- outcome transitions ---

  test "mark_started! is idempotent and does not change outcome" do
    t = AiTask.create!(valid_attrs)
    t.mark_started!(now: Time.current, log_path: "/tmp/x.log")
    assert_equal AiTask::IN_FLIGHT, t.outcome
    assert_predicate t.started_at, :present?
    assert_equal "/tmp/x.log", t.log_path
  end

  test "happy path: in_flight -> done" do
    t = AiTask.create!(valid_attrs)
    t.mark_done!(now: Time.current)
    assert_equal AiTask::DONE, t.outcome
    assert_predicate t.finished_at, :present?
    assert t.terminal?
  end

  test "in_flight -> failed / blocked / needs_review all allowed" do
    %i[mark_failed! mark_blocked! mark_needs_review!].each do |m|
      t = AiTask.create!(valid_attrs)
      t.public_send(m, **{ (m == :mark_failed! ? :error : :reason) => "x", now: Time.current })
      assert t.terminal?, "#{m} should produce a terminal outcome"
    end
  end

  test "double-completion is rejected" do
    t = AiTask.create!(valid_attrs)
    t.mark_done!(now: Time.current)
    assert_raises(AiTask::InvalidTransition) { t.mark_failed!(error: "late", now: Time.current) }
    assert_raises(AiTask::InvalidTransition) { t.mark_done!(now: Time.current) }
  end

  test "retry! resets a terminal task back to in_flight" do
    t = AiTask.create!(valid_attrs)
    t.mark_failed!(error: "x", now: Time.current)
    t.update!(active_job_id: "old-uuid")
    t.retry!
    assert_equal AiTask::IN_FLIGHT, t.outcome
    assert_nil t.error
    assert_nil t.started_at
    assert_nil t.finished_at
    assert_not_equal "old-uuid", t.active_job_id, "retry must produce a new active_job_id"
  end

  test "retry! refuses an in-flight task that is still queued/running" do
    t = AiTask.create!(valid_attrs)
    assert_raises(AiTask::InvalidTransition) { t.retry! }
  end

  test "retry! works when SQ-failed but AiTask still in_flight" do
    t = AiTask.create!(valid_attrs.merge(active_job_id: "old-uuid"))
    fake_presenter = Struct.new(:retryable, :discarded) do
      def label              = :failed
      def retryable?         = retryable
      def discard_queued_job = self.discarded = true
    end.new(true, false)
    t.define_singleton_method(:status) { fake_presenter }

    t.retry!
    assert fake_presenter.discarded, "dead SQ job must be discarded on retry"
    assert_equal AiTask::IN_FLIGHT, t.outcome
    assert_not_equal "old-uuid", t.active_job_id
  end

  test "cancel! requires the presenter to say it's cancellable" do
    t = AiTask.create!(valid_attrs)
    fake_presenter = Struct.new(:cancellable, :discarded) do
      def cancellable? = cancellable
      def discard_queued_job
        self.discarded = true
      end
    end.new(true, false)
    t.define_singleton_method(:status) { fake_presenter }

    assert t.cancel!
    assert_equal AiTask::CANCELLED, t.outcome
    assert fake_presenter.discarded, "cancel! must discard the queued SQ job"
  end

  test "cancel! returns false when presenter says not cancellable (e.g. running)" do
    t = AiTask.create!(valid_attrs)
    not_cancellable = Class.new do
      def cancellable? = false
      def discard_queued_job = raise("should not be called when not cancellable")
    end.new
    t.define_singleton_method(:status) { not_cancellable }

    refute t.cancel!
    assert_equal AiTask::IN_FLIGHT, t.outcome
  end

  test "cancel! is a no-op once already terminal" do
    t = AiTask.create!(valid_attrs)
    t.mark_done!(now: Time.current)
    refute t.cancel!
    assert_equal AiTask::DONE, t.outcome
  end

  # --- recurring ---

  test "recurring? is true when recurring_interval_hours is set" do
    assert AiTask.new(valid_attrs(recurring_interval_hours: 6)).recurring?
    refute AiTask.new(valid_attrs).recurring?
  end

  test "schedule_recurrence! resets task to in_flight and enqueues with wait" do
    t = AiTask.create!(valid_attrs(recurring_interval_hours: 4))
    t.mark_done!(now: Time.current)
    assert_equal AiTask::DONE, t.outcome

    assert_enqueued_with(job: RunClaudeJob) do
      t.schedule_recurrence!
    end

    assert_equal AiTask::IN_FLIGHT, t.outcome
    assert_nil t.error
    assert_nil t.started_at
    assert_nil t.finished_at
    assert_predicate t.active_job_id, :present?
  end
end
