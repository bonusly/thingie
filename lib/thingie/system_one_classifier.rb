# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Thingie
  # Puts typed questions about some state to a System One decision model (e.g. TypeSafe's
  # Jev) and returns its numeric answers. System One models aren't chat models, so this
  # calls the provider's `/v1/systemone` endpoint directly instead of RubyLLM.
  #
  # Disabled unless `system_one_enabled` is true; the provider is set by `system_one_api_base`,
  # `system_one_api_key` and `system_one_model`.
  #
  # @example
  #   SystemOneClassifier.new(config).classify(state: { path: 'a.rb', diff: diff })
  #   # => { security: 0.04, ..., overall: 0.2 }
  class SystemOneClassifier
    PATH = '/v1/systemone'

    # Each risk is a yes/no (`noul`) question with explicit true/false criteria, so the model
    # knows what to look for. `overall` is an ordered `score` question.
    RISK_QUESTIONS = {
      security: {
        type: 'noul',
        instructions: 'Does this change introduce a security vulnerability or weaken a security control?',
        criteria: {
          'true' => 'Adds exposure or removes a protection in authentication, authorization, input validation, ' \
                    'SQL, shell, eval or deserialization, secrets, or cryptography.',
          'false' => 'Refactors, docs, tests, or logic with no effect on a trust boundary.'
        }
      },
      user_impact: {
        type: 'noul',
        instructions: 'Will end users or API clients notice this change?',
        criteria: {
          'true' => 'Changes behavior, output, UI, API responses, stored data, or runs a data migration.',
          'false' => 'Internal-only change with no visible effect, such as a refactor, tests, or tooling.'
        }
      },
      performance: {
        type: 'noul',
        instructions: 'Is this change likely to degrade performance or resource usage?',
        criteria: {
          'true' => 'Adds N+1 or unbounded queries, missing indexes, unbounded loops, blocking calls on a hot ' \
                    'path, or much more memory use.',
          'false' => 'No change to query patterns, algorithmic complexity, or resource use.'
        }
      },
      new_dependencies: {
        type: 'noul',
        instructions: 'Does this change add, remove, or upgrade a third-party dependency?',
        criteria: {
          'true' => 'Adds, removes, or upgrades a gem, package, library, or external service.',
          'false' => 'Uses only dependencies that are already present.'
        }
      },
      maintainability: {
        type: 'noul',
        instructions: 'Does this change make the code harder to understand, test, or maintain?',
        criteria: {
          'true' => 'Adds hard-to-follow, duplicated, or tightly coupled code, or removes tests.',
          'false' => 'Is clear, consistent with the surrounding code, and covered by tests.'
        }
      },
      overall: {
        type: 'score',
        instructions: 'How risky is it to ship this change without a careful human review?',
        criteria: ['Can ship as-is', 'Needs careful review', 'Blocks release']
      }
    }.freeze

    # Build a classifier from the System One settings in the configuration.
    #
    # @param config [Thingie::Configuration] source of the `system_one_*` settings
    # @raise [Thingie::ConfigurationError] if System One isn't enabled with exactly `true`, or the API key,
    #   model, or API base URL is missing
    def initialize(config)
      unless config['system_one_enabled'] == true
        raise ConfigurationError, 'System One is disabled. Set system_one_enabled to true (or SYSTEM_ONE_ENABLED=true).'
      end

      @api_key = required_setting(config, 'system_one_api_key', 'SYSTEM_ONE_API_KEY')
      @model = required_setting(config, 'system_one_model', 'SYSTEM_ONE_MODEL')
      api_base = required_setting(config, 'system_one_api_base', 'SYSTEM_ONE_API_BASE')
      @timeout = config['request_timeout']
      @uri = URI("#{api_base.chomp('/')}#{PATH}")
    end

    # Ask every question about the state in a single request.
    #
    # @param state [Hash, String] what the questions are about
    # @param questions [Hash{Symbol => Hash}] question name => System One question; defaults to {RISK_QUESTIONS}
    # @return [Hash{Symbol => Float}] question name => probability (0.0-1.0) of yes for a `noul`
    #   question, or for a `score` question the probability-weighted position scaled to 0.0-1.0
    #   (0.0 is the first level, 1.0 the last), so every value reads as a risk between 0 and 1
    # @raise [Thingie::SystemOneError] if the request fails, times out, or returns an error or unexpected response
    def classify(state:, questions: RISK_QUESTIONS)
      answers = request(state: state, questions: questions)
      questions.to_h { |name, question| [name.to_sym, value_of(answers.fetch(name.to_s), question)] }
    rescue KeyError, JSON::ParserError => e
      raise SystemOneError, "Unexpected System One response: #{e.message}"
    end

    private

    def required_setting(config, key, env_name)
      value = config[key].to_s.strip
      raise ConfigurationError, "Missing #{env_name}." if value.empty?

      value
    end

    def value_of(answer, question)
      return answer.fetch('noul') unless answer.fetch('type') == 'score'

      answer.fetch('score').to_f / [question[:criteria].size - 1, 1].max
    end

    def request(state:, questions:)
      response = post(model: @model, state: state, questions: questions)
      unless response.is_a?(Net::HTTPSuccess)
        raise SystemOneError, "System One request failed (#{response.code}): #{response.body}"
      end

      JSON.parse(response.body).fetch('answers')
    end

    def post(payload)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == 'https'
      http.open_timeout = http.read_timeout = http.write_timeout = @timeout
      headers = { 'Authorization' => "Bearer #{@api_key}", 'Content-Type' => 'application/json' }
      http.post(@uri.path, JSON.generate(payload), headers)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, SystemCallError => e
      raise SystemOneError, "System One request failed: #{e.class}: #{e.message}"
    end
  end
end
