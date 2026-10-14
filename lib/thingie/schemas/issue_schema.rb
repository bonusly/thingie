# frozen_string_literal: true

module Thingie
  # JSON schema for LLM review responses, used to enforce structured output
  # and avoid markdown-wrapped or malformed JSON.
  module Schemas
    ISSUE_SCHEMA = {
      name: 'thingie_review_issues',
      description: 'Array of code review issues found in the diff',
      strict: true,
      schema: {
        type: 'object',
        properties: {
          issues: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                title: { type: 'string' },
                details: { type: 'string' },
                evidence: { type: 'string' },
                tags: {
                  type: 'array',
                  items: { type: 'string' }
                },
                severity: { type: 'integer' },
                confidence: { type: 'integer' },
                affected_lines: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      start_line: { type: 'integer' },
                      end_line: { type: %w[integer null] },
                      proposal: { type: %w[string null] }
                    },
                    # OpenAI strict mode requires every property in `required`;
                    # optional fields are expressed as nullable types instead.
                    required: %w[start_line end_line proposal],
                    additionalProperties: false
                  }
                }
              },
              required: %w[title details evidence tags severity confidence affected_lines],
              additionalProperties: false
            }
          }
        },
        required: %w[issues],
        additionalProperties: false
      }
    }.freeze
  end
end
