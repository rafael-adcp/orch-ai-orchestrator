class AiTask < ApplicationRecord
  class InvalidTransition < StandardError; end

  STATUSES  = %w[pending running done failed cancelled].freeze
  PROVIDERS = %w[claude].freeze # add "copilot" etc. as support lands

  PENDING, RUNNING, DONE, FAILED, CANCELLED = STATUSES

  # Allowed source states per transition. Tightens the model so callers
  # can't silently flip a finished/cancelled task back into the pipeline.
  TRANSITIONS = {
    RUNNING   => [ PENDING ],
    DONE      => [ RUNNING ],
    FAILED    => [ PENDING, RUNNING ], # failures can fire from either
    CANCELLED => [ PENDING ],
    PENDING   => [ FAILED ]            # only retry-from-failed re-enters pending
  }.freeze

  validates :status,    inclusion: { in: STATUSES }
  validates :provider,  inclusion: { in: PROVIDERS }
  validates :repo_path, :prompt, presence: true

  before_create :assign_id

  scope :pending, -> { where(status: PENDING) }
  scope :running, -> { where(status: RUNNING) }
  scope :recent,  -> { order(created_at: :desc) }

  def enqueue!
    job = ProviderRegistry.job_for(provider).set(priority: -priority).perform_later(id)
    update!(solid_queue_job_id: job.provider_job_id)
  end

  def mark_running!(now:, log_path:)
    transition_to!(RUNNING, started_at: now, log_path: log_path)
  end

  def mark_done!(now:)
    transition_to!(DONE, finished_at: now)
  end

  def mark_failed!(error:, now:)
    transition_to!(FAILED, error: error, finished_at: now)
  end

  def retry!
    transition_to!(PENDING, error: nil, started_at: nil, finished_at: nil)
    enqueue!
  end

  def cancel!
    return false unless can_transition?(CANCELLED)
    transition_to!(CANCELLED)
    true
  end

  def can_transition?(target)
    TRANSITIONS.fetch(target, []).include?(status)
  end

  def log_text
    log_path && File.exist?(log_path) ? File.read(log_path) : nil
  end

  private

  def assign_id
    self.id ||= SecureRandom.hex(6)
  end

  def transition_to!(target, attrs = {})
    unless can_transition?(target)
      raise InvalidTransition, "#{status} -> #{target} not allowed for AiTask #{id}"
    end
    update!(attrs.merge(status: target))
  end
end
