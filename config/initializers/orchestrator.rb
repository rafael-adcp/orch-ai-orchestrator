cfg = Rails.application.config_for(:orchestrator).to_h.with_indifferent_access

# ENV overrides take precedence over YAML defaults.
cfg[:claude_bin]       = ENV.fetch("ORCH_CLAUDE_BIN",    cfg[:claude_bin].to_s)
cfg[:claude_flags]     = ENV.fetch("ORCH_CLAUDE_FLAGS",   cfg[:claude_flags].to_s).split
cfg[:claude_model]     = ENV["ORCH_CLAUDE_MODEL"].presence || cfg[:claude_model]
cfg[:claude_max_turns] = (ENV["ORCH_CLAUDE_MAX_TURNS"] || cfg[:claude_max_turns]).to_i
cfg[:sentinel]         = ENV.key?("ORCH_SENTINEL") ? ENV["ORCH_SENTINEL"] != "0" : cfg[:sentinel]

raise "ORCH_CLAUDE_BIN must not be blank in production" if Rails.env.production? && cfg[:claude_bin].blank?

Rails.application.config.orchestrator = cfg
