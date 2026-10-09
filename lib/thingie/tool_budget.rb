# frozen_string_literal: true

module Thingie
  # Caps how many tool calls one model call may make. Left alone, a model can keep checking: one file review
  # made 60 tool calls and took 22 minutes. The prompt tells the model the number so it spends the calls on what
  # matters most; past it, a tool call returns a note to answer now instead of running, and the time limit on
  # the call remains the backstop. One budget per model call, never shared between calls.
  class ToolBudget
    SPENT = 'Tool budget spent: no more tool calls for this review. Answer now with what you have, and grade ' \
            'anything you could not check at a lower confidence.'

    attr_reader :limit, :used, :refused

    # Builds a budget for one model call.
    #
    # @param limit [Integer, nil] the most tool calls allowed; nil or 0 means no cap
    def initialize(limit)
      @limit = limit.to_i
      @used = 0
      @refused = 0
    end

    # Whether there is a cap at all.
    #
    # @return [Boolean]
    def active?
      @limit.positive?
    end

    # Copies of the tools that draw on this budget. The originals are untouched, so the same tools can be
    # given to the next call with a fresh budget.
    #
    # @param tools [Array<RubyLLM::Tool>] the tools for one model call
    # @return [Array<RubyLLM::Tool>] the copies, or the tools themselves when there is no cap
    def wrap(tools)
      return tools unless active?

      tools.map { |tool| budgeted(tool) }
    end

    # Runs the block when the budget allows, and returns {SPENT} once it is used up.
    #
    # @yieldreturn [Object] the tool's result
    # @return [Object] the tool's result, or the note to answer now
    def spend
      if @used < @limit
        @used += 1
        yield
      else
        @refused += 1
        SPENT
      end
    end

    private

    # ruby_llm 1.16 calls `tool.call(args)` and 2.x calls `tool.call(**args, tool_call:)`; passing everything
    # through covers both.
    def budgeted(tool)
      budget = self
      tool.dup.tap do |copy|
        copy.define_singleton_method(:call) { |*args, **options| budget.spend { super(*args, **options) } }
      end
    end
  end
end
