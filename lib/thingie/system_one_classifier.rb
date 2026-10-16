# frozen_string_literal: true

require 'ruby_llm'
require_relative 'errors'

module Thingie
  # Puts typed questions about some state to a System One decision model (e.g. TypeSafe's
  # Jev) and returns its numeric answers. System One models aren't chat models, so this uses
  # ruby_llm's judgment API against the TypeSafe-compatible `/v1/systemone` endpoint that
  # `system_one_api_base` names.
  #
  # Disabled unless `system_one_enabled` is true; the provider is set by `system_one_api_base`,
  # `system_one_api_key` and `system_one_model`.
  #
  # @example
  #   SystemOneClassifier.new(config).classify(state: { path: 'a.rb', diff: diff }, questions: risk_questions.questions)
  #   # => { security: 0.04, ..., overall: 0.2 }
  class SystemOneClassifier
    # Build a classifier from the System One settings in the configuration.
    #
    # @param config [Thingie::Configuration] source of the `system_one_*` settings
    # @raise [Thingie::ConfigurationError] if System One isn't enabled with exactly `true`, or the API key,
    #   model, or API base URL is missing
    def initialize(config)
      unless config['system_one_enabled'] == true
        raise ConfigurationError, 'System One is disabled. Set system_one_enabled to true (or SYSTEM_ONE_ENABLED=true).'
      end

      api_key = required_setting(config, 'system_one_api_key', 'SYSTEM_ONE_API_KEY')
      @model = required_setting(config, 'system_one_model', 'SYSTEM_ONE_MODEL')
      api_base = required_setting(config, 'system_one_api_base', 'SYSTEM_ONE_API_BASE')
      @llm_context = build_context(config, api_base, api_key)
    end

    # Per-instance RubyLLM context; configuration never mutates global state, so
    # it coexists with the review's {LlmClient#llm_context}.
    attr_reader :llm_context

    # Ask every question about the state in a single request.
    #
    # @param state [Hash, String] what the questions are about
    # @param questions [Hash{Symbol => Hash}] question name => System One question, e.g. {RiskQuestions#questions}
    # @return [Hash{Symbol => Float}] question name => probability (0.0-1.0) of yes for a `probability`
    #   question, or for a `score` question the probability-weighted position scaled to 0.0-1.0
    #   (0.0 is the first level, 1.0 the last), so every value reads as a risk between 0 and 1
    # @raise [Thingie::SystemOneError] if the request fails, times out, or returns an error or unexpected response
    def classify(state:, questions:)
      judgment = @llm_context.judge(state, questions: questions, provider: :typesafe, model: @model,
                                           assume_model_exists: true)
      questions.to_h { |name, question| [name.to_sym, value_of(judgment.fetch(name), question)] }
    rescue RubyLLM::Error, Faraday::Error => e
      raise SystemOneError, "System One request failed: #{e.class}: #{e.message}"
    rescue KeyError, ArgumentError, TypeError => e
      raise SystemOneError, "Unexpected System One response: #{e.message}"
    end

    private

    def build_context(config, api_base, api_key)
      RubyLLM.context do |llm_config|
        llm_config.typesafe_api_base = api_base.chomp('/')
        llm_config.typesafe_api_key = api_key
        llm_config.request_timeout = config['request_timeout'] if config['request_timeout']
        llm_config.max_retries = config['retries'] if config['retries']
      end
    end

    def required_setting(config, key, env_name)
      value = config[key].to_s.strip
      raise ConfigurationError, "Missing #{env_name}." if value.empty?

      value
    end

    def value_of(answer, question)
      return in_range(Float(answer.probability), 1) unless question[:type] == :score

      top = question[:levels].size - 1
      in_range(Float(answer.score), top) / [top, 1].max
    end

    # @raise [ArgumentError] if the value is not finite or outside 0..max
    def in_range(value, max)
      raise ArgumentError, "score #{value} is outside 0..#{max}" unless value.finite? && value.between?(0, max)

      value
    end
  end
end
