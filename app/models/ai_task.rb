class AiTask < ApplicationRecord
  STATUSES  = %w[pending running done failed cancelled].freeze
  PROVIDERS = %w[claude].freeze # add "copilot" etc. as support lands

  validates :status,    inclusion: { in: STATUSES }
  validates :provider,  inclusion: { in: PROVIDERS }
  validates :repo_path, :prompt, presence: true

  before_create :assign_id

  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :recent,  -> { order(created_at: :desc) }

  def enqueue!
    job = job_class.set(priority: -priority).perform_later(id)
    update!(solid_queue_job_id: job.provider_job_id)
  end

  def log_text
    log_path && File.exist?(log_path) ? File.read(log_path) : nil
  end

  private

  def job_class
    case provider
    when "claude" then RunClaudeJob
    else raise ArgumentError, "no job for provider=#{provider.inspect}"
    end
  end

  def assign_id
    self.id ||= SecureRandom.hex(6)
  end
end
