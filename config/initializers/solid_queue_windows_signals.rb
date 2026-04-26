# Solid Queue's supervisor traps SIGQUIT, which doesn't exist on Windows,
# causing `ArgumentError: unsupported signal SIGQUIT` at boot.
# Re-define the signal list to only those Windows actually supports.
if Gem.win_platform?
  require "solid_queue"
  require "solid_queue/supervisor"

  module SolidQueue
    class Supervisor
      module Signals
        remove_const(:SIGNALS) if const_defined?(:SIGNALS, false)
        SIGNALS = %i[ INT TERM ].freeze
      end
    end
  end
end
