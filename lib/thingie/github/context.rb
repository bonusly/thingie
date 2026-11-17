# frozen_string_literal: true

require 'json'

module Thingie
  module GitHub
    # Helper to read repository and PR context from GitHub Actions environment.
    class Context
      # Builds a Context from the standard GitHub Actions environment variables
      # (`GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`, `PR_NUMBER_FROM_WORKFLOW_DISPATCH`).
      #
      # @return [Thingie::GitHub::Context] the context built from the environment
      def self.from_env
        new(
          repo: Env.fetch('GITHUB_REPOSITORY', nil),
          event_path: Env.fetch('GITHUB_EVENT_PATH', nil),
          workflow_pr: Env.fetch('PR_NUMBER_FROM_WORKFLOW_DISPATCH', nil)
        )
      end

      attr_reader :repo, :event_path, :workflow_pr

      # Builds a context from already-resolved values (see {.from_env} for the usual entry point).
      #
      # @param repo [String, nil] the `owner/repo` slug
      # @param event_path [String, nil] path to the GitHub Actions event JSON payload
      # @param workflow_pr [String, nil] PR number supplied via `workflow_dispatch`, if any
      def initialize(repo:, event_path:, workflow_pr:)
        @repo = repo
        @event_path = event_path
        @workflow_pr = workflow_pr
      end

      # The pull request number, preferring the `workflow_dispatch` input over
      # the event payload's `pull_request.number`.
      #
      # @return [Integer, nil] the PR number, or `nil` if it can't be determined
      def pr_number
        raw = @workflow_pr unless @workflow_pr.nil? || @workflow_pr.to_s.strip.empty?
        raw ||= event_payload&.dig('pull_request', 'number')
        raw && Integer(raw, exception: false)
      end

      # The repository owner, parsed from `repo`.
      #
      # @return [String, nil] the repository owner, parsed from `repo`
      def owner
        repo&.split('/')&.first
      end

      # The repository name, parsed from `repo`.
      #
      # @return [String, nil] the repository name, parsed from `repo`
      def repo_name
        repo&.split('/')&.last
      end

      private

      def event_payload
        return @event_payload if defined?(@event_payload)

        @event_payload =
          (JSON.parse(File.read(@event_path)) if @event_path && File.file?(@event_path))
      end
    end
  end
end
