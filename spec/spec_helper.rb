# frozen_string_literal: true

require 'active_support'
require 'active_support/notifications'
require 'method_timer'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.after { MethodTimer.uninstall }
end
