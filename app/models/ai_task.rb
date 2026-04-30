class AiTask < ApplicationRecord
  class InvalidTransition < StandardError; end

  # OUTCOMES describes the *application*-level result of a task. Execution
  # mechanics (queued / running / scheduled / retrying) are read from
  # Solid Queue via TaskStatus — never duplicated here.
  OUTCOMES = %w[in_flight done failed cancelled needs_review blocked].freeze
  PROVIDERS = %w[claude].freeze

  IN_FLIGHT, DONE, FAILED, CANCELLED, NEEDS_REVIEW, BLOCKED = OUTCOMES
  TERMINAL = (OUTCOMES - [ IN_FLIGHT ]).freeze

  validates :outcome,   inclusion: { in: OUTCOMES }
  validates :provider,  inclusion: { in: PROVIDERS }
  validates :repo_path, :prompt, presence: true

  before_create :assign_id

  scope :in_flight, -> { where(outcome: IN_FLIGHT) }
  scope :recent,    -> { order(created_at: :desc) }

  def enqueue!
    job = ProviderRegistry.job_for(provider).set(priority: -priority).perform_later(id)
    update!(active_job_id: job.job_id)
  end

  def mark_started!(now:, log_path:)
    update!(started_at: now, log_path: log_path)
  end

  def mark_done!(now:)
    transition_to_terminal!(DONE, finished_at: now)
  end

  def mark_failed!(error:, now:)
    transition_to_terminal!(FAILED, error: error, finished_at: now)
  end

  def mark_needs_review!(reason:, now:)
    transition_to_terminal!(NEEDS_REVIEW, error: reason, finished_at: now)
  end

  def mark_blocked!(reason:, now:)
    transition_to_terminal!(BLOCKED, error: reason, finished_at: now)
  end

  def retry!
    raise InvalidTransition, "cannot retry an in-flight task #{id}" if in_flight?
    update!(outcome: IN_FLIGHT, error: nil, started_at: nil, finished_at: nil, active_job_id: nil)
    enqueue!
  end

  def cancel!
    presenter = status
    return false unless in_flight? && presenter.cancellable?
    transition_to_terminal!(CANCELLED, finished_at: Time.current)
    presenter.discard_queued_job
    true
  end

  def in_flight?  = outcome == IN_FLIGHT
  def terminal?   = TERMINAL.include?(outcome)

  def status
    @status ||= TaskStatus.new(self)
  end

  def log_text
    log_path && File.exist?(log_path) ? File.read(log_path) : nil
  end

  private

  def assign_id
    self.id ||= SecureRandom.hex(6)
  end

  def transition_to_terminal!(target, attrs = {})
    raise InvalidTransition, "#{outcome} -> #{target} not allowed for AiTask #{id}" unless in_flight?
    update!(attrs.merge(outcome: target))
    @status = nil
  end
end
