# frozen_string_literal: true

module Thingie
  # One line naming a tool call for a finding's debugging record: the tool name and what it was asked.
  module ToolCallLabel
    LIMIT = 100

    # The label for one call.
    #
    # @param name [String] the tool name
    # @param arguments [Hash] the call's arguments
    # @return [String] e.g. `search amounts_within_max`, trimmed to LIMIT characters
    def self.for(name, arguments)
      detail = arguments.to_h.values.reject { |value| value.nil? || value == false }.join(' ')
      detail = "#{detail[0, LIMIT - 3]}..." if detail.length > LIMIT
      detail.empty? ? name.to_s : "#{name} #{detail}"
    end
  end
end
