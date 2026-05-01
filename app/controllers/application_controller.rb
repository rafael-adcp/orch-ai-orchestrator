class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_user_timezone

  private

  def set_user_timezone
    cfg = Rails.application.config.orchestrator
    tz  = cookies[cfg[:timezone_cookie]].presence
    Time.zone = (tz && ActiveSupport::TimeZone[tz]) || cfg[:default_timezone]
  end

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from ActiveRecord::RecordNotFound do
    render plain: "Not found", status: :not_found
  end
end
