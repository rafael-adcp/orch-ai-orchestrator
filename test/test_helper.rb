ENV["RAILS_ENV"] ||= "test"
require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  add_filter "/test/"
  add_filter "/config/"
  add_filter "/db/"
  add_filter "/bin/"
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
