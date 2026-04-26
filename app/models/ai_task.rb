class AiTask < ApplicationRecord
  STATUSES  = %w[pending running done failed cancelled].freeze
  PROVIDERS = %w[claude].freeze # add "copilot" etc. as support lands

  PENDING, RUNNING, DONE, FAILED, CANCELLED = STATUSES

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
    update!(status: RUNNING, started_at: now, log_path: log_path)
  end

  def mark_done!(now:)
    update!(status: DONE, finished_at: now)
  end

  def mark_failed!(error:, now:)
    update!(status: FAILED, error: error, finished_at: now)
  end

  def retry!
    update!(status: PENDING, error: nil, started_at: nil, finished_at: nil)
    enqueue!
  end

  def cancel!
    update!(status: CANCELLED) if status == PENDING
  end

  def log_text
    log_path && File.exist?(log_path) ? File.read(log_path) : nil
  end

  private

  def assign_id
    self.id ||= SecureRandom.hex(6)
  end
end
