# Register each provider here. Adding a new provider:
#   1) Create app/jobs/run_<name>_job.rb
#   2) Add the provider name to AiTask::PROVIDERS
#   3) Register the mapping below
Rails.application.config.to_prepare do
  ProviderRegistry.reset!
  ProviderRegistry.register("claude", RunClaudeJob)
end
