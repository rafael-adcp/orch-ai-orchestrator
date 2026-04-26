ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/spec"

module ActiveSupport
  class TestCase
    parallelize(workers: 1)
    fixtures :all if respond_to?(:fixtures)
  end
end

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }
