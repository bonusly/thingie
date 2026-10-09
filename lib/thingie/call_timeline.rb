# frozen_string_literal: true

module Thingie
  # Times one model call that may use tools, to show in the debug log where a slow call spent its time: in the
  # tools, or in the model and the network. Fed by the chat's before-tool and after-tool hooks.
  class CallTimeline
    SLOWEST_SHOWN = 3

    # Starts the clock for one call.
    def initialize
      @started = now
      @open = []
      @tools = []
      @busy = 0.0
      @busy_since = nil
    end

    # Notes that a tool call began.
    #
    # @param label [String] the tool name and what it was asked, for example `search amounts_within_max`
    # @return [void]
    def tool_started(label)
      at = now
      @busy_since = at if @open.empty?
      @open << [label, at]
    end

    # Notes that the oldest running tool call finished. Tools may overlap, so calls are matched in the order
    # they started.
    #
    # @return [void]
    def tool_finished
      label, began = @open.shift
      return if label.nil?

      at = now
      @tools << [label, at - began]
      return unless @open.empty?

      @busy += at - @busy_since
      @busy_since = nil
    end

    # One line: the total time, the share spent in tools, and the slowest tool calls.
    #
    # @return [String] the line, for example `total 412.3s | tools 13 calls 30.4s | model and network 381.9s`
    def summary
      at = now
      total = at - @started
      tool_time = @busy + (@busy_since ? at - @busy_since : 0.0)
      parts = ["total #{seconds(total)}", "tools #{@tools.size} calls #{seconds(tool_time)}",
               "model and network #{seconds([total - tool_time, 0.0].max)}"]
      parts << "unfinished tool calls #{@open.size}" unless @open.empty?
      slowest = @tools.max_by(SLOWEST_SHOWN) { |_, took| took }
      parts << "slowest tools: #{slowest.map { |label, took| "#{label} #{seconds(took)}" }.join(', ')}" if slowest.any?
      parts.join(' | ')
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def seconds(value)
      "#{value.round(1)}s"
    end
  end
end
