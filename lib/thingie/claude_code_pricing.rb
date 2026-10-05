# frozen_string_literal: true

module Thingie
  # Prices a Claude Code run from its token counts using the ruby_llm model
  # registry (the same source the default review's costs come from). The CLI
  # only knows Claude prices, so its own `total_cost_usd` is wrong for any
  # other model routed through an Anthropic-compatible endpoint.
  module ClaudeCodePricing
    module_function

    # The run's cost in USD: from the registry when it prices the model, else
    # the CLI's figure.
    #
    # @param result [Hash] the CLI's result event (`usage`, `total_cost_usd`)
    # @param model [String, nil] the model the run used
    # @param provider [String, nil] the ruby_llm provider the model is listed under
    # @return [Array(Numeric, String)] the cost and where it came from (`registry` or `cli`)
    def cost(result, model:, provider:)
      rates = registry_rates(model, provider)
      return [result['total_cost_usd'], 'cli'] unless rates

      usage = result['usage'] || {}
      total = (usage['input_tokens'].to_f * rates[:input]) +
              (usage['cache_read_input_tokens'].to_f * (rates[:cache_read] || rates[:input])) +
              (usage['cache_creation_input_tokens'].to_f * (rates[:cache_write] || rates[:input])) +
              (usage['output_tokens'].to_f * rates[:output])
      [(total / 1_000_000).round(6), 'registry']
    end

    # Per-million-token rates for `model`, or nil when the registry does not
    # price it (unknown model, or a ruby_llm version with another pricing shape).
    #
    # @param model [String, nil] model id
    # @param provider [String, nil] provider slug
    # @return [Hash{Symbol=>Float}, nil] `input`, `output`, and optional `cache_read`/`cache_write`
    def registry_rates(model, provider)
      return if model.to_s.empty?

      info = RubyLLM.models.find(model, provider)
      tier = info.pricing.text_tokens.standard
      input = tier.input_per_million
      output = tier.output_per_million
      return unless input && output

      { input: input.to_f, output: output.to_f,
        cache_read: tier.cache_read_input_per_million&.to_f, cache_write: tier.cache_write_input_per_million&.to_f }
    rescue StandardError
      nil
    end
  end
end
