# frozen_string_literal: true

module Thingie
  module Stats
    # Pure field builders for the structured stats events, extracted so
    # {Emitter} stays under RuboCop's class-length cap. Each method returns a
    # string-keyed Hash of event-specific fields; {Emitter#emit} merges them
    # with the common fields and dispatches to the sinks.
    module Events
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
          'dry_run' => dry_run
        }
      end
    end
  end
end
