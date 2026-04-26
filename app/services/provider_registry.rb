# Maps provider name (string) -> ActiveJob class.
# New providers register themselves at boot via an initializer.
class ProviderRegistry
  class UnknownProvider < StandardError; end

  @registry = {}

  class << self
    def register(provider, job_class)
      @registry[provider.to_s] = job_class
    end

    def job_for(provider)
      @registry.fetch(provider.to_s) { raise UnknownProvider, provider.inspect }
    end

    def known
      @registry.keys
    end

    def reset!
      @registry = {}
    end
  end
end
