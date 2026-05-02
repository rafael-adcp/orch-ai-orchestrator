require "test_helper"
require "capybara/rails"
require "capybara/minitest"

# Distinguish this suite from the unit/integration runner so SimpleCov
# merges the two resultsets instead of letting the second invocation
# overwrite the first.
SimpleCov.command_name "Capybara"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # rack_test = no browser process, runs headless on any OS, no Chrome/geckodriver needed.
  # Trade-off: no JavaScript. Plenty for our forms (no JS-driven flows yet).
  driven_by :rack_test
end
