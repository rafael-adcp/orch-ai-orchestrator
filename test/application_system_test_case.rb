require "test_helper"
require "capybara/rails"
require "capybara/minitest"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # rack_test = no browser process, runs headless on any OS, no Chrome/geckodriver needed.
  # Trade-off: no JavaScript. Plenty for our forms (no JS-driven flows yet).
  driven_by :rack_test
end
