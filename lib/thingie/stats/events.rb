# frozen_string_literal: true

module Thingie
  module Stats
    # Pure field builders for the structured stats events, extracted so
    # {Emitter} stays under RuboCop's class-length cap. Each method returns a
    # string-keyed Hash of event-specific fields; {Emitter#emit} merges them
    # with the common fields and dispatches to the sinks.
    module Events
      # Builds the `review.completed` event fields from the report and run
      # telemetry.
      #
      # @param report [Thingie::Report] the finished review report
      # @param duration_ms [Integer] wall-clock review duration in milliseconds
      # @param usage [Thingie::Stats::Usage] accumulated LLM usage for the run
      # @return [Hash{String=>Object}] event-specific fields for `emit`
      def self.review_completed(report, duration_ms, usage)
        {
          'commit_sha' => report.target.commit_sha,
          'branch' => report.target.branch,
          'model' => report.model,
          'files_reviewed' => report.number_of_processed_files,
          'total_issues' => report.total_issues,
          'issues_by_severity' => severity_counts(report.issues),
          'issues_by_tag' => tag_counts(report.issues),
          'duration_ms' => duration_ms,
          'usage' => usage.to_h
        }
      end

      # Builds the `approval.decided` event fields from the approver's
      # decision.
      #
      # @param action [Symbol] `:approve`, `:block`, or `:skip`
      # @param reasons [Array<String>] block reasons (empty for approve/skip)
      # @param repo [String, nil] the `owner/repo` slug
      # @param pr_number [Integer, nil] the pull request number
      # @param dry_run [Boolean] whether approval is in dry-run mode
      # @return [Hash{String=>Object}] event-specific fields for `emit`
      def self.approval_decided(action:, reasons:, repo:, pr_number:, dry_run:)
        {
          'action' => action.to_s,
          'reasons' => Array(reasons),
          'repo' => repo,
          'pr_number' => pr_number,
          'dry_run' => dry_run ? true : false
        }
      end

      # Counts surviving issues per severity, keyed by the string severity
      # number (`"1"`..`"4"`). Issues with a nil severity are skipped.
      #
      # @param issues [Array<Thingie::Issue>] the report's issues
      # @return [Hash{String=>Integer}] severity => count
      def self.severity_counts(issues)
        issues.each_with_object({}) do |issue, counts|
          next if issue.severity.nil?

          key = issue.severity.to_s
          counts[key] = (counts[key] || 0) + 1
        end
      end

      # Tallies every tag across the issues into a `tag => count` Hash.
      #
      # @param issues [Array<Thingie::Issue>] the report's issues
      # @return [Hash{String=>Integer}] tag => count
      def self.tag_counts(issues)
        issues.flat_map { |issue| Array(issue.tags) }.tally
      end
    end
  end
end
