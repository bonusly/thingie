# frozen_string_literal: true

# Top-level namespace for Thingie. The CLI, configuration, review engine, and
# reporters all live under the Thingie module.
module Thingie
end

require_relative 'thingie/errors'
require_relative 'thingie/version'
require_relative 'thingie/env'
require_relative 'thingie/threshold'
require_relative 'thingie/configuration'
require_relative 'thingie/skill_catalog'
require_relative 'thingie/prompt_builder'
require_relative 'thingie/models'
require_relative 'thingie/changeset'
require_relative 'thingie/issue_parser'
require_relative 'thingie/schemas/issue_schema'
require_relative 'thingie/schemas/verdict_schema'
require_relative 'thingie/schemas/risk_assessment_schema'
require_relative 'thingie/code_enricher'
require_relative 'thingie/post_processor'
require_relative 'thingie/debug_output'
require_relative 'thingie/llm_client'
require_relative 'thingie/concurrency'
require_relative 'thingie/verifier'
require_relative 'thingie/obfuscation_detector'
require_relative 'thingie/lsp/client'
require_relative 'thingie/lsp/symbol_tool'
require_relative 'thingie/mcp/server_config'
require_relative 'thingie/mcp/toolset'
require_relative 'thingie/file_tool'
require_relative 'thingie/report_renderer'
require_relative 'thingie/json_extractor'
require_relative 'thingie/reviewer'
require_relative 'thingie/github'
require_relative 'thingie/stats'
