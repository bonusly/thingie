# frozen_string_literal: true

# Top-level namespace for Thingie. The CLI, configuration, and the GitHub
# auto-approver all live under the Thingie module.
module Thingie
end

require_relative 'thingie/version'
require_relative 'thingie/env'
require_relative 'thingie/configuration'
require_relative 'thingie/obfuscation_detector'
require_relative 'thingie/github'
require_relative 'thingie/stats'
