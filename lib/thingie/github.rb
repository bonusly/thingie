# frozen_string_literal: true

module Thingie
  # GitHub integration: the auto-approver and the Actions context it reads.
  module GitHub
  end
end

require_relative 'github/context'
require_relative 'github/linked_runs'
require_relative 'github/approver'
