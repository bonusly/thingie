# frozen_string_literal: true

module Thingie
  # GitHub integration helpers for posting PR reviews and reading Actions context.
  module GitHub
  end
end

require_relative 'github/context'
require_relative 'github/pacing'
require_relative 'github/graphql_client'
require_relative 'github/commenter'
require_relative 'github/approver'
