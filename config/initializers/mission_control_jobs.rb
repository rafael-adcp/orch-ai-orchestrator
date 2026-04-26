# Mission Control Jobs ships with HTTP Basic auth on by default and 401s
# when credentials are unset. Disable in development; set explicit creds via
# MISSION_CONTROL_USER / MISSION_CONTROL_PASSWORD in production environments.
Rails.application.config.after_initialize do
  if defined?(MissionControl::Jobs)
    if Rails.env.development? || Rails.env.test?
      MissionControl::Jobs.http_basic_auth_enabled = false
    elsif ENV["MISSION_CONTROL_USER"] && ENV["MISSION_CONTROL_PASSWORD"]
      MissionControl::Jobs.http_basic_auth_user     = ENV["MISSION_CONTROL_USER"]
      MissionControl::Jobs.http_basic_auth_password = ENV["MISSION_CONTROL_PASSWORD"]
    end
  end
end
