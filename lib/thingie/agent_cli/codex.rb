# frozen_string_literal: true

require 'json'
require 'ruby_llm'
require_relative '../errors'
require_relative '../tool_call_label'

module Thingie
  module AgentCli
    # `codex exec` on the developer's Codex login, ignoring their config.toml, in a read-only sandbox.
    class Codex
      COMMAND = 'codex'

      # Shown when `codex` is not on PATH.
      #
      # @return [String] how to sign in when the CLI is missing
      def login_hint = 'run `codex login`'

      # The `codex exec` command line for one call.
      #
      # @param model [String, nil] a Codex model slug; nil runs Codex's default model
      # @param schema_path [String] path of the JSON Schema the reply must match
      # @param workdir [String] the repository root
      # @return [Array<String>] the command line
      def argv(model:, schema_path:, workdir:)
        [COMMAND, 'exec', '-', '--json', '--output-schema', schema_path, *(['-m', model] if model),
         '--ephemeral', '--ignore-user-config', '--sandbox', 'read-only', '--skip-git-repo-check',
         '--color', 'never', '-C', workdir]
      end

      # Reads the last agent message, usage and command runs from the run's events.
      #
      # @param stdout [String] the run's JSONL events
      # @param model [String] the requested model
      # @raise [Thingie::AgentCliError] if the run reports a failure
      # @return [Thingie::AgentCli::Client::Result, nil] the reply, or nil when there is no agent message
      def parse(stdout, model:)
        content = nil
        tokens = RubyLLM::Tokens.new
        labels = []
        stdout.each_line do |raw|
          line = parse_line(raw)
          case line&.fetch('type', nil)
          when 'item.completed'
            item = line['item'] || {}
            item['type'] == 'agent_message' ? content = item['text'] : labels.concat(tool_labels(item))
          when 'turn.completed' then tokens = tokens(line)
          when 'turn.failed', 'error' then raise AgentCliError, "codex: #{error_message(line)}"
          end
        end
        content && Client::Result.new(content: content, tokens: tokens, model: model, tool_labels: labels)
      end

      private

      def parse_line(raw)
        line = JSON.parse(raw)
        line if line.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def tool_labels(item)
        case item['type']
        when 'command_execution' then [ToolCallLabel.for('command', 'command' => item['command'])]
        when 'web_search' then [ToolCallLabel.for('web_search', 'query' => item['query'])]
        else []
        end
      end

      # Codex counts cached tokens inside `input_tokens`; ruby_llm's `input` is the uncached part.
      def tokens(line)
        usage = line['usage'] || {}
        input = usage['input_tokens'] && (usage['input_tokens'] - usage['cached_input_tokens'].to_i)
        RubyLLM::Tokens.new(input: input, output: usage['output_tokens'],
                            cache_read: usage['cached_input_tokens'],
                            cache_write: usage['cache_write_input_tokens'],
                            thinking: usage['reasoning_output_tokens'])
      end

      # An API failure arrives as the API's JSON error body inside `message`; its own message is the readable part.
      def error_message(line)
        message = line.dig('error', 'message') || line['message'] || line.to_json
        body = JSON.parse(message)
        (body.dig('error', 'message') if body.is_a?(Hash)) || message
      rescue JSON::ParserError
        message
      end
    end
  end
end
