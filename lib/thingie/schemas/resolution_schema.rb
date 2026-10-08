# frozen_string_literal: true

module Thingie
  module Schemas
    # JSON schema for the resolution check: for each earlier finding, whether the problem it describes
    # is gone from the current code.
    RESOLUTION_SCHEMA = {
      name: 'thingie_resolution_check',
      description: 'For each earlier review finding, whether the problem is fixed in the current code',
      strict: true,
      schema: {
        type: 'object',
        properties: {
          findings: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                status: { type: 'string', enum: %w[fixed still_present unsure] }
              },
              required: %w[id status],
              additionalProperties: false
            }
          }
        },
        required: %w[findings],
        additionalProperties: false
      }
    }.freeze
  end
end
