# frozen_string_literal: true

module Thingie
  # Caps how many tool calls one model call may make. Left alone, a model can keep checking: one file review
  # made 60 tool calls and took 22 minutes. The prompt tells the model the number so it spends the calls on what
  # matters most; past it, a tool call returns a note to answer now instead of running, and the time limit on
  # the call remains the backstop. One budget per model call, never shared between calls.
  #
  # A call that fails (a path that does not exist, a search that errors, a tool that raises) comes back fast and
  # tells the model nothing about the code, so it is not charged. Up to `limit` failures are free; past that
  # they count like any other call, so a model stuck on bad paths still runs out.
  class ToolBudget
    SPENT = 'Tool budget spent: no more tool calls for this review. Answer now with what you have, and grade ' \
            'anything you could not check at a lower confidence.'

    # A tool result that reports a failed call rather than an answer. It reads as the plain message to the model.
    class Failure < String; end

    attr_reader :limit, :used, :refused, :failed

    # Builds a budget for one model call.
    #
    # @param limit [Integer, nil] the most tool calls allowed; nil or 0 means no cap
    def initialize(limit)
      @limit = limit.to_i
      @used = 0
      @refused = 0
      @failed = 0
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

    # Runs the block when the budget allows, and returns {SPENT} once it is used up. A {Failure} result or an
    # error gives the call back, while free failures remain.
    #
    # @yieldreturn [Object] the tool's result
    # @return [Object] the tool's result, or the note to answer now
    def spend
      return refuse unless @used < @limit

      @used += 1
      result = yield
      refund if result.is_a?(Failure)
      result
    rescue StandardError
      refund
      raise
    end

    private

    def refuse
      @refused += 1
      SPENT
    end

    def refund
      return unless @failed < @limit

      @failed += 1
      @used -= 1
    end

    # ruby_llm calls `tool.call(**args, tool_call:)`; pass everything through so the copy stays a drop-in.
    def budgeted(tool)
      budget = self
      tool.dup.tap do |copy|
        copy.define_singleton_method(:call) { |*args, **options| budget.spend { super(*args, **options) } }
      end
    end
  end
end
