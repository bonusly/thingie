# frozen_string_literal: true

require 'json'

module Thingie
  # The `claude -p --output-format stream-json` transcript: one JSON event per
  # line, ending in a `result` event. Keeping the whole stream (rather than the
  # final result alone) is what lets a reader see which files the run read,
  # which subagents it spawned, and why it said what it said.
  class ClaudeCodeTranscript
    # Parses the CLI's stdout. A plain `--output-format json` result (one JSON
    # object, possibly after a log line) is accepted too.
    #
    # @param stdout [String] the CLI's stdout
    # @return [ClaudeCodeTranscript] the parsed transcript
    def self.parse(stdout)
      events = stdout.to_s.each_line.filter_map do |line|
        parsed = JsonExtractor.parse(line)
        parsed if parsed.is_a?(Hash)
      end
      new(events)
    end

    # Wraps already-parsed events; use {.parse} for raw stdout.
    #
    # @param events [Array<Hash>] the stream events in order
    def initialize(events)
      @events = events
    end

    # The final `result` event, or the lone object of a non-streamed result.
    #
    # @return [Hash, nil] the result, nil when the run produced none
    def result
      @events.reverse.find { |event| event['type'] == 'result' } || (@events.size == 1 ? @events.first : nil)
    end

    # Why a failed run failed: the CLI reports its own errors (auth, API) in the
    # result text with nothing on stderr, so prefer that.
    #
    # @param stderr [String] the CLI's stderr
    # @return [String] the reason, trimmed
    def failure_reason(stderr)
      text = result.is_a?(Hash) ? result['result'].to_s : ''
      (text.strip.empty? ? stderr.to_s : text).strip[0, 500]
    end

    # How many times each tool was called across the run, as "Read ×3, Grep ×1".
    #
    # @return [String, nil] the summary, nil when no tool was called
    def tool_calls
      counts = @events.select { |event| event['type'] == 'assistant' }
                      .flat_map { |event| Array(event.dig('message', 'content')) }
                      .select { |block| block.is_a?(Hash) && block['type'] == 'tool_use' }
                      .group_by { |block| block['name'].to_s }
      return if counts.empty?

      counts.map { |name, blocks| "#{name} ×#{blocks.size}" }.join(', ')
    end

    # How many subagents the run spawned, when the CLI reports it.
    #
    # @return [Integer, nil] spawned subagents
    def subagents
      result&.dig('subagent_stats', 'spawned')
    end
  end
end
