# frozen_string_literal: true

module Thingie
  # Filters issues using simple numeric thresholds from configuration.
  # Lower numbers are more severe / more confident, so an issue is kept when
  # its confidence and severity are at or below the configured maximums.
  #
  # Severity is capped before the critic pass (#call). Confidence is capped after it
  # (#cap_confidence), on the grade the critic gave once it had checked the code, because the
  # confidence a reviewer writes about its own finding comes before any checking. With System One
  # ratings, a trivial or routine file keeps only a Critical graded confidence 1, except security findings.
  #
  # Uses plain comparisons rather than evaluating a config-supplied Ruby
  # expression, which avoids arbitrary code execution at the config boundary.
  class PostProcessor
    # Ratings of files on which only a Critical the critic is sure of survives: see {#split_confidence}.
    LOW_RISK_RATINGS = %w[trivial routine].freeze

    # Builds a filter from the `[post_process]` config section.
    #
    # @param settings [Hash, nil] the `[post_process]` config section: `max_confidence`/`max_severity`, and
    #   `require_evidence` (a finding with no evidence is graded `unverified_confidence`, default 3)
    # @param file_ratings [Hash{String => String}] path => System One rating (one of {RiskQuestions::LEVELS});
    #   empty when System One is disabled or scoring failed, so no file is treated as low risk
    def initialize(settings, file_ratings: {})
      settings = (settings || {}).transform_keys(&:to_s)
      @require_evidence = settings['require_evidence'] == true
      @unverified_confidence = Integer(settings.fetch('unverified_confidence', 3), exception: false) || 3
      # Parse thresholds once; an absent/invalid value means "no limit".
      @max_confidence = Threshold.parse(settings['max_confidence'])
      @max_severity = Threshold.parse(settings['max_severity'])
      @low_risk_files = file_ratings.select { |_path, rating| LOW_RISK_RATINGS.include?(rating) }.keys
    end

    # Keep only the issues at or below the configured `max_severity` threshold.
    #
    # @param issues [Array<Thingie::Issue>] issues to filter
    # @return [Array<Thingie::Issue>] the surviving issues
    def call(issues)
      issues.select { |issue| within?(issue.severity, @max_severity) }
    end

    # Keep only the issues at or below the configured `max_confidence`, judged on the grade each has
    # after the critic pass. With `require_evidence`, a finding with no evidence is first held to no
    # better than `unverified_confidence`, so the critic's grade cannot lift it past a strict cap.
    #
    # Outside a low-risk file (see {#split_confidence}), a finding the critic never graded is kept whatever
    # its first-pass confidence: the cap judges the critic's grade, and dropping an unchecked finding would
    # hide it from the reader and the approver. A Critical is kept there too: an under-graded SQL injection
    # must still get a thread and block approval.
    #
    # @param issues [Array<Thingie::Issue>] issues that survived the critic pass
    # @return [Array<Thingie::Issue>] the issues at or below `max_confidence`, plus any left unchecked
    def cap_confidence(issues)
      split_confidence(issues).first
    end

    # Like {#cap_confidence}, but also returns the findings it holds back rather than dropping them.
    #
    # @param issues [Array<Thingie::Issue>] issues that survived the critic pass
    # @return [Array(Array<Thingie::Issue>, Array<Thingie::Issue>)] `[kept, held_back]`
    def split_confidence(issues)
      issues.each { |issue| demote_unverified(issue) } if @require_evidence
      issues.partition { |issue| keep_after_critic?(issue) }
    end

    private

    # On a trivial or routine file only a Critical graded confidence 1 is kept, on whatever grade the finding
    # has now (the critic's, or its own when the critic never graded it): the file carries little risk, so the
    # rest is more likely a nit or a false positive. A `security` finding keeps the normal bar on every file.
    def keep_after_critic?(issue)
      return critical?(issue) && Integer(issue.confidence, exception: false) == 1 if low_risk?(issue)

      issue.unchecked? || critical?(issue) || within?(issue.confidence, @max_confidence)
    end

    def low_risk?(issue)
      @low_risk_files.include?(issue.file) && !issue.tags.include?('security')
    end

    def critical?(issue)
      Integer(issue.severity, exception: false) == 1
    end

    # A finding the reviewer gave no evidence for cannot claim more confidence than the
    # unverified grade, whatever number the model or the critic wrote.
    def demote_unverified(issue)
      return unless issue.evidence.to_s.strip.empty?

      current = Integer(issue.confidence, exception: false)
      issue.apply_override(confidence: @unverified_confidence) if current.nil? || current < @unverified_confidence
    end

    def within?(value, max)
      return true if max.nil?

      value_int = Integer(value, exception: false)
      value_int.nil? || value_int <= max
    end
  end
end
