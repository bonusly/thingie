# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require 'ruby_llm'
require_relative '../errors'
require_relative 'claude_code'
require_relative 'codex'

module Thingie
  module AgentCli
    # Runs each model call as one headless run of an installed agent CLI, on the developer's own
    # subscription login. The CLI brings its own read-only repository tools, so ruby_llm tools are
    # not passed and nothing is added to `chats` (the follow-up in the same conversation is skipped).
    class Client
      PROVIDERS = { 'claude-code' => ClaudeCode, 'codex' => Codex }.freeze

      # What an adapter reads from a run's output.
      Result = Struct.new(:content, :tokens, :model, :tool_labels, keyword_init: true)

      # Whether a provider name is run through an agent CLI rather than ruby_llm.
      #
      # @param name [String, nil] a `provider` config value
      # @return [Boolean] whether `name` names an agent CLI provider
      def self.provider?(name)
        PROVIDERS.key?(name.to_s.downcase)
      end

      # Whether the model at config path `keys` may be sent. Config files (bundled and project) name models of
      # the project's API provider, so an agent CLI takes only a model set on this machine (an env var such as
      # `LLM_MODEL` / `VERIFY_MODEL`, or a CLI flag) and otherwise runs on its own default model.
      #
      # @param config [Thingie::Configuration] the resolved run configuration
      # @param keys [Array<String>] path of the model setting, e.g. `` `verify`, `model` ``
      # @return [Boolean] always true for an API provider
      def self.usable_model?(config, *keys)
        !provider?(config['provider']) || config.set_locally?(*keys)
      end

      # Picks the adapter for `config['provider']`.
      #
      # @param config [Thingie::Configuration] the resolved run configuration
      # @param model [String, nil] optional model override (falls back to `config['model']` when set on this
      #   machine; see {.usable_model?})
      def initialize(config, model: nil)
        @config = config
        @model = model || (config['model'] if self.class.usable_model?(config, 'model'))
        @adapter = PROVIDERS.fetch(config['provider'].to_s.downcase).new
      end

      # Same signature as LlmClient#complete_with_schema. `tools`, `tool_budget` and `chats` are accepted
      # for that contract and ignored.
      #
      # @param prompt [String] the prompt text, sent on stdin
      # @param schema [Hash] a Thingie schema (`{ name:, schema: }`); only the inner JSON Schema is used
      # @param tools [Array] ignored; the CLI brings its own tools
      # @param tool_log [Array<String>, nil] filled with a label for each repository tool the CLI ran
      # @param tool_budget [Thingie::ToolBudget, nil] ignored; the run is bounded by `call_timeout`
      # @param chats [Array, nil] ignored; a CLI run has no conversation to follow up in
      # @raise [Thingie::AgentCliError] if the run fails or answers without a result
      # @raise [Thingie::ConfigurationError] if the CLI is not installed
      # @return [RubyLLM::Message] the reply; content is the structured output as a JSON string
      def complete_with_schema(prompt, schema, tools: [], tool_log: nil, tool_budget: nil, chats: nil) # rubocop:disable Lint/UnusedMethodArgument
        result = Tempfile.create(['thingie-schema', '.json']) do |file|
          file.write(JSON.generate(schema[:schema] || schema['schema']))
          file.flush
          call(prompt, @adapter.argv(model: @model, schema_path: file.path, workdir: @config.root))
        end
        tool_log&.concat(result.tool_labels)
        RubyLLM::Message.new(role: :assistant, content: result.content, model: result.model, tokens: result.tokens,
                             cost: RubyLLM::Cost.new(tokens: result.tokens))
      end

      private

      def call(prompt, argv)
        output, errors, status = run(argv, prompt)
        result = @adapter.parse(output, model: @model)
        return result if result

        raise AgentCliError, "#{argv.first} exited #{status.exitstatus}: #{tail(errors)}" unless status.success?

        raise AgentCliError, "#{argv.first} produced no result"
      end

      def tail(text)
        text = text.to_s.strip
        text.length > 500 ? text[-500..] : text
      end

      # The CLI runs in its own process group, so the `ensure` kills it and the tools it started when a call
      # timeout unwinds through the block.
      def run(argv, prompt)
        Open3.popen3(*argv, chdir: @config.root, pgroup: true) do |stdin, stdout, stderr, waiter|
          errors = Thread.new { read_stderr(stderr) }
          finished = false
          begin
            write_prompt(stdin, prompt)
            output = stdout.read
            status = waiter.value
            finished = true
            [output, errors.value, status]
          ensure
            stop(waiter) unless finished
          end
        end
      rescue Errno::ENOENT
        raise ConfigurationError, "#{argv.first} not found on PATH. Install it and sign in (#{@adapter.login_hint})."
      end

      # A CLI that exits before reading its input reports why on stderr and in its exit status.
      def write_prompt(stdin, prompt)
        stdin.write(prompt)
      rescue Errno::EPIPE
        nil
      ensure
        stdin.close
      end

      # Closing the pipes on an early exit ends the read.
      def read_stderr(stderr)
        stderr.read.to_s
      rescue IOError
        ''
      end

      def stop(waiter)
        Process.kill('TERM', -waiter.pid)
        Process.kill('KILL', -waiter.pid) unless waiter.join(2)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
