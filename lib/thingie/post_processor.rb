# frozen_string_literal: true

module Thingie
  # Filters issues using simple numeric thresholds from configuration.
  # Lower numbers are more severe / more confident, so an issue is kept when
  # its confidence and severity are at or below the configured maximums.
  #
  # Uses plain comparisons rather than evaluating a config-supplied Ruby
  # expression, which avoids arbitrary code execution at the config boundary.
  class PostProcessor
    # Builds a filter from the `[post_process]` config section.
    #
    # @param settings [Hash, nil] the `[post_process]` config section: `max_confidence`/`max_severity`, and
    #   `require_evidence` (a finding with no evidence is graded `unverified_confidence`, default 3), and
    #   `confidence_after_verify` (apply `max_confidence` after the critic pass, to the grade it gives)
    def initialize(settings)
      settings = (settings || {}).transform_keys(&:to_s)
      @confidence_after_verify = settings['confidence_after_verify'] == true
      @require_evidence = settings['require_evidence'] == true
      @unverified_confidence = Integer(settings.fetch('unverified_confidence', 3), exception: false) || 3
      # Parse thresholds once; an absent/invalid value means "no limit".
      @max_confidence = Threshold.parse(settings['max_confidence'])
      @max_severity = Threshold.parse(settings['max_severity'])
    end

    # Keep only the issues at or below the configured `max_confidence`/`max_severity` thresholds.
    #
    # @param issues [Array<Thingie::Issue>] issues to filter
    # @return [Array<Thingie::Issue>] the surviving issues
    def call(issues)
      issues.each { |issue| demote_unverified(issue) } if @require_evidence
      issues.select { |issue| keep?(issue) }
    end

    # Apply `max_confidence` to the grade each finding has after the critic pass. A no-op unless
    # `confidence_after_verify` is set, in which case #call left the confidence alone.
    #
    # @param issues [Array<Thingie::Issue>] issues that survived the critic pass
    # @return [Array<Thingie::Issue>] the issues at or below `max_confidence`
    def cap_confidence(issues)
      return issues unless @confidence_after_verify

      issues.select { |issue| within?(issue.confidence, @max_confidence) }
    end

    private

    # A finding the reviewer gave no evidence for cannot claim more confidence than the
    # unverified grade, whatever number the model wrote.
    def demote_unverified(issue)
      return unless issue.evidence.to_s.strip.empty?

      current = Integer(issue.confidence, exception: false)
      issue.apply_override(confidence: @unverified_confidence) if current.nil? || current < @unverified_confidence
    end

    def keep?(issue)
      (@confidence_after_verify || within?(issue.confidence, @max_confidence)) && within?(issue.severity, @max_severity)
    end

    def within?(value, max)
      return true if max.nil?

      value_int = Integer(value, exception: false)
      value_int.nil? || value_int <= max
    end
  end
end
