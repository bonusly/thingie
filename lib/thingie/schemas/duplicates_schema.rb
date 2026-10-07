# frozen_string_literal: true

module Thingie
  module Schemas
    # JSON schema for the duplicate check: for each new finding, the label of an
    # earlier finding or open review comment it repeats, or null when it is new.
    # `duplicate_of` is nullable rather than omittable because OpenAI strict-mode
    # schemas require every property to be listed in `required`.
    DUPLICATES_SCHEMA = {
      name: 'thingie_duplicate_check',
      description: 'For each new review finding, which earlier finding or open comment it repeats, if any',
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
                duplicate_of: { type: %w[string null] }
              },
              required: %w[id duplicate_of],
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
