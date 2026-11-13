# frozen_string_literal: true

require 'octokit'

module Thingie
  module GitHub
    # Finds the GitHub Actions runs a pull request links to, in the given repositories, that
    # ran a commit not on that repository's default branch. A workflow dispatched with
    # `--ref some-branch` runs that branch's copy of the workflow file, which main may never
    # have had, e.g. one with test settings left in.
    class LinkedRuns
      # On the default branch: the run's commit is main's head or behind it.
      ON_BRANCH_STATUSES = %w[identical behind].freeze

      # Builds a checker for the given repositories' runs.
      #
      # @param clients [Array<Octokit::Client>] tried in order for each read
      # @param repos [Array<String>] "owner/name" repositories whose runs are checked
      def initialize(clients:, repos:)
        @clients = clients
        @repos = repos
      end

      # The linked runs that ran a commit off their repository's default branch.
      #
      # @param texts [Array<String, nil>] the PR description and comment bodies
      # @return [Array<String>] one line per linked run off the default branch, e.g.
      #   "bonusly/loop-de-loop run 123 ran from test-branch, not main"
      def off_default_branch(texts)
        text = texts.compact.join("\n")
        @repos.flat_map do |repo|
          run_ids(repo, text).filter_map { |id| off_default_branch_line(repo, id) }
        end
      end

      private

      def run_ids(repo, text)
        text.scan(%r{https://github\.com/#{Regexp.escape(repo)}/actions/runs/(\d+)}i).flatten.uniq
      end

      # nil when the run is on the default branch, or when it can't be read: only a confirmed
      # off-branch run blocks.
      def off_default_branch_line(repo, id)
        with_client("check #{repo} run #{id}") do |client|
          run = client.workflow_run(repo, id.to_i)
          main = client.repository(repo).default_branch
          next if ON_BRANCH_STATUSES.include?(client.compare(repo, main, run.head_sha).status)

          "#{repo} run #{id} ran from #{run.head_branch}, not #{main}"
        end
      end

      def with_client(action)
        last_error = nil
        @clients.each do |client|
          return yield(client)
        rescue Octokit::Error => e
          last_error = e
        end
        warn "Could not #{action} — #{last_error&.message}"
        nil
      end
    end
  end
end
