# frozen_string_literal: true

require 'json'
require 'ruby_llm'
require_relative '../errors'
require_relative '../tool_call_label'

module Thingie
  module AgentCli
    # `claude -p` in safe mode: the developer's Claude Code login, no hooks, plugins, MCP servers or
    # CLAUDE.md, and only the read-only Read/Grep/Glob tools.
    class ClaudeCode
      COMMAND = 'claude'
      TOOLS = 'Read,Grep,Glob'

      # Shown when `claude` is not on PATH.
      #
      # @return [String] how to sign in when the CLI is missing
      def login_hint = 'run `claude auth login`'

      # The `claude -p` command line for one call.
      #
      # @param model [String, nil] a Claude model alias or id; nil runs Claude Code's default model
      # @param schema_path [String] path of the JSON Schema the reply must match
      # @param workdir [String] the repository root (the run is already started there)
      # @return [Array<String>] the command line
      def argv(model:, schema_path:, workdir:) # rubocop:disable Lint/UnusedMethodArgument
        [COMMAND, '-p', '--safe-mode', '--output-format', 'stream-json', '--verbose',
         '--json-schema', File.read(schema_path), *(['--model', model] if model),
         '--tools', TOOLS, '--allowedTools', TOOLS, '--permission-prompts', 'none',
         '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence']
      end

      # Reads the reply, usage and repository tool calls from the run's output.
      #
      # @param stdout [String] the run's stream-json output
      # @param model [String] the requested model, used when the run names none
      # @raise [Thingie::AgentCliError] if the run reports a failure
      # @return [Thingie::AgentCli::Client::Result, nil] the reply, or nil when there is no result line
      def parse(stdout, model:)
        labels = []
        stdout.each_line do |raw|
          line = parse_line(raw)
          case line&.fetch('type', nil)
          when 'assistant' then labels.concat(tool_labels(line))
          when 'result' then return result(line, labels, model)
          end
        end
        nil
      end

      private

      def parse_line(raw)
        line = JSON.parse(raw)
        line if line.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def tool_labels(line)
        Array(line.dig('message', 'content')).filter_map do |block|
          next unless block['type'] == 'tool_use' && block['name'] != 'StructuredOutput'

          ToolCallLabel.for(block['name'], block['input'])
        end
      end

      def result(line, labels, model)
        raise AgentCliError, "claude: #{line['result']}" if line['is_error'] || line['subtype'] != 'success'

        content = line.key?('structured_output') ? JSON.generate(line['structured_output']) : line['result'].to_s
        Client::Result.new(content: content, tokens: tokens(line), tool_labels: labels,
                           model: line['modelUsage']&.keys&.first || model)
      end

      def tokens(line)
        usage = line['usage'] || {}
        RubyLLM::Tokens.new(input: usage['input_tokens'], output: usage['output_tokens'],
                            cache_read: usage['cache_read_input_tokens'],
                            cache_write: usage['cache_creation_input_tokens'],
                            thinking: usage.dig('output_tokens_details', 'thinking_tokens'),
                            reported_cost: line['total_cost_usd'])
      end
    end
  end
end
