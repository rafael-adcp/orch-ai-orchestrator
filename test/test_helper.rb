ENV["RAILS_ENV"] ||= "test"
require "simplecov"
require "simplecov-cobertura"
SimpleCov.start "rails" do
  enable_coverage :branch
  command_name "Minitest"
  merge_timeout 3600
  add_filter "/test/"
  add_filter "/config/"
  add_filter "/db/"
  add_filter "/bin/"
  # Subprocess#run is the real IO.popen seam. AGENTS.md §1: tests inject
  # fakes; only the real seam touches the world. Excluded by design.
  add_filter "app/services/subprocess.rb"
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
end
require_relative "../config/environment"
require "rails/test_help"
require "minitest/spec"

Rails.application.eager_load!

module ActiveSupport
  class TestCase
    parallelize(workers: 1)
    fixtures :all if respond_to?(:fixtures)
  end
end

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }
