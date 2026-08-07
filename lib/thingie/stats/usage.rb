# frozen_string_literal: true

module Thingie
  module Stats
    # Mutable accumulator for LLM token usage and cost across a single review
    # run. The Reviewer and Verifier feed it each `ruby_llm` response; the
    # Emitter serializes the totals into the `review.completed` event.
    #
    # Stats must never break a review — `#record` is nil-tolerant and rescues
    # any `StandardError` (mirroring `DebugOutput`'s defensive reads). Tokens
    # are summed first, cost last, so a raising cost accessor can't lose token
    # data.
    class Usage
      attr_reader :input_tokens, :output_tokens, :cache_read_tokens,
                  :cache_write_tokens, :cost

      # Builds an empty accumulator; all counters start nil and fill on the
      # first `#record`.
      def initialize
        @input_tokens = nil
        @output_tokens = nil
        @cache_read_tokens = nil
        @cache_write_tokens = nil
        @cost = nil
      end

      # Adds the token fields and cost from a `ruby_llm` response into the
      # running totals. No-op when `response` is nil. Each token field is added
      # only when the value is a `Numeric`; cost is read via
      # `response.cost&.total`. The whole body is rescued so a malformed
      # response can never fail a review.
      #
      # @param response [Object, nil] the `ruby_llm` response object
      # @return [void]
      def record(response)
        return unless response

        add_input(response)
        add_cost(response)
      rescue StandardError
        nil
      end

      # Serializes the accumulated totals into a string-keyed Hash with nils
      # intact (so an unused counter serializes as JSON `null`, not `0`).
      #
      # @return [Hash{String=>Integer, Float, nil}] the usage totals
      def to_h
        {
          'input_tokens' => @input_tokens,
          'output_tokens' => @output_tokens,
          'cache_read_tokens' => @cache_read_tokens,
          'cache_write_tokens' => @cache_write_tokens,
          'cost_usd' => @cost
        }
      end

      private

      def add_input(response)
        @input_tokens = add_numeric(@input_tokens, response.input_tokens)
        @output_tokens = add_numeric(@output_tokens, response.output_tokens)
        @cache_read_tokens = add_numeric(@cache_read_tokens, response.cache_read_tokens)
        @cache_write_tokens = add_numeric(@cache_write_tokens, response.cache_write_tokens)
      end

      def add_cost(response)
        total = response.cost&.total
        return unless total.is_a?(Numeric)

        @cost = (@cost || 0) + total
      end

      def add_numeric(running, value)
        value.is_a?(Numeric) ? (running || 0) + value : running
      end
    end
  end
end
