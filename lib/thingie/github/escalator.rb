# frozen_string_literal: true

require 'octokit'

module Thingie
  module GitHub
    # Applies the `[[escalations]]` rules to a change-risk score: every rule whose
    # threshold the score reaches adds its label to the pull request.
    #
    # Labels only raise a flag. They never change the review or approval outcome.
    class Escalator
      # Build an escalator for one pull request.
      #
      # @param token [String] GitHub token allowed to label pull requests
      # @param owner [String] the repository owner
      # @param repo [String] the repository name
      # @param pr_number [Integer] the pull request number
      # @param rules [Array<Hash>] `[[escalations]]` entries, each with a `threshold` (0.0-1.0) and a `label`
      # @raise [Thingie::ConfigurationError] if a rule has no valid threshold or label
      def initialize(token:, owner:, repo:, pr_number:, rules:)
        @client = Octokit::Client.new(access_token: token)
        @slug = "#{owner}/#{repo}"
        @pr_number = pr_number
        @rules = rules.each { |rule| validate(rule) }
      end

      # Label the pull request for every rule the score reaches and remove the labels of the
      # rules it no longer reaches, so the labels follow the current diff. Every label named
      # in a rule is managed here, so don't reuse one for something applied by hand.
      #
      # @param score [Float] the overall change-risk score, 0.0-1.0
      # @return [Array<String>] the labels added, empty when no rule matched
      def call(score)
        labels = @rules.select { |rule| score >= rule['threshold'] }.map { |rule| rule['label'] }.uniq
        @client.add_labels_to_an_issue(@slug, @pr_number, labels) unless labels.empty?
        (managed_labels - labels).each { |label| remove(label) }
        labels
      end

      private

      def managed_labels
        @rules.map { |rule| rule['label'] }.uniq
      end

      # A label that isn't on the PR is already in the desired state.
      def remove(label)
        @client.remove_label(@slug, @pr_number, label)
      rescue Octokit::NotFound
        nil
      end

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
end
