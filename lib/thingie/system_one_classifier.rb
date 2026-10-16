# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
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
  #   SystemOneClassifier.new(config).classify(state: { path: 'a.rb', diff: diff }, questions: risk_questions.questions)
  #   # => { security: 0.04, ..., overall: 0.2 }
  class SystemOneClassifier
    PATH = '/v1/systemone'
    ERROR_BODY_LIMIT = 200

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
    # @param questions [Hash{Symbol => Hash}] question name => System One question, e.g. {RiskQuestions#questions}
    # @return [Hash{Symbol => Float}] question name => probability (0.0-1.0) of yes for a `noul`
    #   question, or for a `score` question the probability-weighted position scaled to 0.0-1.0
    #   (0.0 is the first level, 1.0 the last), so every value reads as a risk between 0 and 1
    # @raise [Thingie::SystemOneError] if the request fails, times out, or returns an error or unexpected response
    def classify(state:, questions:)
      answers = request(state: state, questions: questions)
      questions.to_h { |name, question| [name.to_sym, value_of(answers.fetch(name.to_s), question)] }
    rescue KeyError, TypeError, ArgumentError, JSON::ParserError => e
      raise SystemOneError, "Unexpected System One response: #{e.message}"
    end

    private

    def required_setting(config, key, env_name)
      value = config[key].to_s.strip
      raise ConfigurationError, "Missing #{env_name}." if value.empty?

      value
    end

    def value_of(answer, question)
      raise TypeError, "answer is #{answer.class}, not an object" unless answer.is_a?(Hash)
      return in_range(Float(answer.fetch('noul')), 1) unless answer.fetch('type') == 'score'

      top = question[:criteria].size - 1
      in_range(Float(answer.fetch('score')), top) / [top, 1].max
    end

    # @raise [ArgumentError] if the value is not finite or outside 0..max
    def in_range(value, max)
      raise ArgumentError, "score #{value} is outside 0..#{max}" unless value.finite? && value.between?(0, max)

      value
    end

    def request(state:, questions:)
      response = post(model: @model, state: state, questions: questions)
      unless response.is_a?(Net::HTTPSuccess)
        raise SystemOneError, "System One request failed (#{response.code}): #{response.body.to_s[0, ERROR_BODY_LIMIT]}"
      end

      answers = JSON.parse(response.body).fetch('answers')
      raise TypeError, "answers is #{answers.class}, not an object" unless answers.is_a?(Hash)

      answers
    end

    # Posts once more on a timeout, 429 or 5xx.
    def post(payload)
      response = begin
        attempt(payload)
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
        nil
      end
      response = attempt(payload) if response.nil? || retryable?(response)
      response
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
           IOError, Net::ProtocolError, Net::HTTPBadResponse => e
      raise SystemOneError, "System One request failed: #{e.class}: #{e.message}"
    end

    def retryable?(response)
      response.is_a?(Net::HTTPTooManyRequests) || response.is_a?(Net::HTTPServerError)
    end

    def attempt(payload)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == 'https'
      http.open_timeout = http.read_timeout = http.write_timeout = @timeout
      headers = { 'Authorization' => "Bearer #{@api_key}", 'Content-Type' => 'application/json' }
      http.post(@uri.path, JSON.generate(payload), headers)
    end
  end
end
