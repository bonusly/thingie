# frozen_string_literal: true

module Thingie
  # The `[[escalations]]` config rules: each maps an overall change-risk score threshold to a PR
  # label, with an optional title and description shown in the review.
  class EscalationRules
    # Validate and hold the rules.
    #
    # @param rules [Array<Hash>, nil] `[[escalations]]` entries, each with a `threshold` (0.0-1.0), a `label`,
    #   and optionally a `title` and `description`
    # @raise [Thingie::ConfigurationError] if a rule has no valid threshold or label
    def initialize(rules)
      @rules = Array(rules).each { |rule| validate(rule) }
    end

    # Whether any rule is configured.
    #
    # @return [Boolean] true when no rules are configured
    def empty?
      @rules.empty?
    end

    # The escalations the score reaches, as the report records them.
    #
    # @param score [Float] the overall change-risk score, 0.0-1.0
    # @return [Array<Hash>] one per label, each with a `label` and the configured `title` and `description`
    def matching(score)
      @rules.select { |rule| score >= rule['threshold'] }.uniq { |rule| rule['label'] }.map do |rule|
        rule.slice('label', 'title', 'description').reject { |_, value| value.to_s.strip.empty? }
      end
    end

    # The labels of every rule the score reaches.
    #
    # @param score [Float] the overall change-risk score, 0.0-1.0
    # @return [Array<String>] the matching labels, without duplicates
    def labels_for(score)
      matching(score).map { |escalation| escalation['label'] }
    end

    # Every label the rules can apply, whether or not the score reaches it.
    #
    # @return [Array<String>] the labels, without duplicates
    def managed_labels
      @rules.map { |rule| rule['label'] }.uniq
    end

    private

    def validate(rule)
      threshold = rule['threshold']
      unless threshold.is_a?(Numeric) && threshold.between?(0, 1)
        raise ConfigurationError, "escalations threshold must be a number from 0 to 1, got #{threshold.inspect}"
      end
      return unless rule['label'].to_s.strip.empty?

      raise ConfigurationError, 'escalations label must not be blank'
    end
  end
end
