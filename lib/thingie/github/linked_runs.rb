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

      # off_branch: runs confirmed off the default branch. unchecked: runs no client could read.
      Result = Struct.new(:off_branch, :unchecked)

      # Builds a checker for the given repositories' runs.
      #
      # @param clients [Array<Octokit::Client>] tried in order for each read
      # @param repos [Array<String>] "owner/name" repositories whose runs are checked
      def initialize(clients:, repos:)
        @clients = clients
        @repos = repos
        @default_branches = {}
      end

      # Sorts the linked runs into those off their repository's default branch and those that
      # couldn't be read.
      #
      # @param texts [Array<String, nil>] the PR description and comment bodies
      # @return [Result] one line per run in each list, e.g.
      #   "bonusly/loop-de-loop run 123 ran from `test-branch`, not main"
      def check(texts)
        text = texts.compact.join("\n")
        result = Result.new([], [])
        @repos.each do |repo|
          run_ids(repo, text).each { |id| sort_run(repo, id, result) }
        end
        result
      end

      private

      def run_ids(repo, text)
        text.scan(%r{(?:https?://)?(?:www\.)?github\.com/#{Regexp.escape(repo)}/actions/runs/(\d+)}i).flatten.uniq
      end

      def sort_run(repo, id, result)
        checked = with_client("check #{repo} run #{id}") do |client|
          run = client.workflow_run(repo, id.to_i)
          main = default_branch(client, repo)
          next :on_branch if ON_BRANCH_STATUSES.include?(client.compare(repo, main, run.head_sha).status)

          "#{repo} run #{id} ran from `#{ref_name(run)}`, not #{main}"
        end
        case checked
        when :on_branch then nil
        when nil then result.unchecked << "#{repo} run #{id}"
        else result.off_branch << checked
        end
      end

      def default_branch(client, repo)
        @default_branches[repo] ||= client.repository(repo).default_branch
      end

      def ref_name(run)
        (run.head_branch || run.head_sha.to_s[0, 7]).to_s.delete('`')
      end

      def with_client(action)
        last_error = nil
        @clients.each do |client|
          return yield(client)
        rescue Octokit::Error, Faraday::Error => e
          last_error = e
        end
        warn "Could not #{action} — #{last_error&.message}"
        nil
      end
    end
  end
end
