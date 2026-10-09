# frozen_string_literal: true

require 'logger'
require 'ruby_llm'
require_relative 'errors'

module Thingie
  # Thin wrapper around ruby_llm for code review prompts.
  class LlmClient
    # The longest a tool call's label gets in a finding's debugging record.
    LABEL_LIMIT = 100

    # Maps Thingie provider names to the RubyLLM config attribute names.
    PROVIDER_CONFIG = {
      'openai' => { key: :openai_api_key, base: :openai_api_base },
      'anthropic' => { key: :anthropic_api_key, base: :anthropic_api_base },
      'gemini' => { key: :gemini_api_key, base: :gemini_api_base },
      'ollama' => { key: :ollama_api_key, base: :ollama_api_base },
      'deepseek' => { key: :deepseek_api_key, base: :deepseek_api_base },
      'openrouter' => { key: :openrouter_api_key, base: :openrouter_api_base },
      'mistral' => { key: :mistral_api_key, base: :mistral_api_base },
      'perplexity' => { key: :perplexity_api_key, base: :perplexity_api_base },
      'xai' => { key: :xai_api_key, base: :xai_api_base },
      'azure' => { key: :azure_api_key, base: :azure_api_base },
      'bedrock' => { key: :bedrock_api_key, base: :bedrock_api_base },
      'vertexai' => { key: :vertexai_service_account_key, base: :vertexai_api_base },
      'gpustack' => { key: :gpustack_api_key, base: :gpustack_api_base }
    }.freeze

    LOG_LEVELS = {
      'debug' => Logger::DEBUG, 'info' => Logger::INFO, 'warn' => Logger::WARN,
      'error' => Logger::ERROR, 'fatal' => Logger::FATAL
    }.freeze

    # `model` overrides config['model'] (same provider/keys) — used to run the
    # critic pass on a stronger model than the review.
    #
    # @param config [Thingie::Configuration] the resolved run configuration
    # @param model [String, nil] optional model override (falls back to `config['model']`)
    # @raise [Thingie::ConfigurationError] if `llm_api_key` is missing from config
    def initialize(config, model: nil)
      @config = config
      @model = model || config['model']
      validate!
      load_local_models_registry
      @llm_context = build_context
    end

    # Per-instance RubyLLM context; configuration never mutates global state, so
    # multiple clients with different providers/keys can coexist safely.
    attr_reader :llm_context

    # Sends a prompt to the LLM and parses the response against a structured
    # output schema.
    #
    # @param prompt [String] the prompt text to send
    # @param schema [Object] the structured output schema the response must conform to; skipped when tools are
    #   given and `schema_with_tools` is false (the prompt then carries the JSON shape and the reply is parsed)
    # @param tools [Array<Object>] optional `ruby_llm` tools to make available for tool-use
    # @param tool_log [Array<String>, nil] filled with a label for each tool call the model makes: the tool name
    #   and what it was asked, for example `search amounts_within_max`
    # @param tool_budget [Thingie::ToolBudget, nil] caps the tool calls this one call may make
    # @return [Object] the `ruby_llm` response
    def complete_with_schema(prompt, schema, tools: [], tool_log: nil, tool_budget: nil)
      tools = tool_budget.wrap(tools) if tool_budget
      c = chat
      c = c.with_tools(*tools) unless tools.empty?
      c = LlmCompat.with_request_params(c, provider: { require_parameters: true }) if tool_capable_routing?(tools)
      c = LlmCompat.on_tool_call(c, ->(call) { tool_log << tool_call_label(call) }) if tool_log
      c = c.with_schema(schema) unless tools.any? && @config['schema_with_tools'] == false
      c.ask(prompt)
    end

    # Applies the configured provider's API key/base to a RubyLLM config
    # object. Accepts either a per-context config (from `RubyLLM.context`) or
    # the global `RubyLLM.config`, so the `models` command can reuse it to make
    # provider credentials visible to the model registry refresh.
    #
    # @param llm_config [Object] a `RubyLLM` config object (per-context or global)
    # @param config [Thingie::Configuration] the resolved run configuration
    # @raise [ArgumentError] if `config['provider']` is not a supported provider
    # @return [void]
    def self.apply_provider_config!(llm_config, config)
      provider = config['provider'].to_s.downcase
      mapping = PROVIDER_CONFIG[provider]
      raise ArgumentError, "Unsupported LLM provider: #{provider}" unless mapping

      llm_config.public_send("#{mapping[:key]}=", config['llm_api_key'])
      llm_config.public_send("#{mapping[:base]}=", config['llm_api_base']) if config['llm_api_base']
    end

    private

    # OpenRouter spreads one model over many providers, and some of them drop the tools from a request
    # and answer without them. `require_parameters` keeps a call with tools on providers that take them.
    def tool_capable_routing?(tools)
      tools.any? && provider == 'openrouter' && @config.dig('openrouter', 'require_parameters') != false
    end

    # The tool name and its arguments on one line, trimmed, for the debugging record of a finding.
    def tool_call_label(call)
      detail = call.arguments.to_h.values.reject { |value| value.nil? || value == false }.join(' ')
      detail = "#{detail[0, LABEL_LIMIT - 3]}..." if detail.length > LABEL_LIMIT
      detail.empty? ? call.name : "#{call.name} #{detail}"
    end

    def validate!
      return if @config['llm_api_key'] && !@config['llm_api_key'].to_s.strip.empty?

      raise ConfigurationError,
            'Missing LLM_API_KEY. Set it as an environment variable or in ~/.thingie/.env.'
    end

    # When `models_file` is configured and exists, point the process-wide
    # RubyLLM model registry at it and (re)load it, so reviews use the local
    # registry instead of the (potentially stale) one shipped with the gem.
    # RubyLLM's model registry is a process-wide singleton resolved from the
    # global RubyLLM.config, so this is the one global mutation the client
    # makes; provider keys/base stay per-context. A missing file is ignored so
    # reviews fall back to the shipped registry until `thingie models` creates it.
    def load_local_models_registry
      path = @config['models_file']
      return unless path && !path.to_s.strip.empty?

      expanded = File.expand_path(path)
      return unless File.exist?(expanded)

      RubyLLM.config.model_registry_file = expanded
      LlmCompat.load_models_from_json(expanded)
    end

    def build_context
      RubyLLM.context do |llm_config|
        apply_provider_config(llm_config)
        llm_config.request_timeout = @config['request_timeout'] if @config['request_timeout']
        llm_config.max_retries = @config['retries'] if @config['retries']
        apply_logging_config(llm_config)
      end
    end

    def apply_logging_config(llm_config)
      log_file = @config['log_file']
      llm_config.log_file = log_file if log_file && !log_file.to_s.strip.empty?

      level = parse_log_level(@config['log_level'])
      llm_config.log_level = level if level
    end

    def parse_log_level(value)
      return nil unless value && !value.to_s.strip.empty?
      return value if value.is_a?(Integer) # already a Logger level

      LOG_LEVELS.fetch(value.to_s.downcase, Logger::INFO)
    end

    def chat
      llm_context.chat(model: @model, provider: provider)
    end

    def provider
      @config['provider'].to_s.downcase
    end

    def apply_provider_config(llm_config)
      self.class.apply_provider_config!(llm_config, @config)
    end
  end
end
