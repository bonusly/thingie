# frozen_string_literal: true

require 'json'

module Thingie
  module GitHub
    # Minimal GraphQL client wrapper around Octokit for resolving review threads and hiding stale comments.
    class GraphqlClient
      THREAD_PAGE_SIZE = 100

      # Wraps an existing Octokit client for GraphQL requests.
      #
      # @param client [Octokit::Client] the Octokit client used to issue GraphQL requests
      def initialize(client)
        @client = client
      end

      # Fetches all review threads for a pull request.
      #
      # @param owner [String] the repository owner
      # @param repo [String] the repository name
      # @param pr_number [Integer] the pull request number
      # @raise [RuntimeError] if the GraphQL response contains top-level errors
      # @return [Array<Hash>] the review thread nodes (string-keyed)
      def review_threads(owner:, repo:, pr_number:)
        response = post_graphql(review_threads_query, thread_variables(owner, repo, pr_number))
        body = stringify(to_hash(response))
        raise_on_errors(body)
        body.dig('data', 'repository', 'pullRequest', 'reviewThreads', 'nodes') || []
      end

      # Resolves a single review thread via the `resolveReviewThread` mutation.
      #
      # @param thread_id [String] the GraphQL node ID of the thread to resolve
      # @raise [RuntimeError] if the GraphQL response contains top-level errors
      # @return [Object] the raw Octokit response
      def resolve_thread(thread_id)
        response = post_graphql(resolve_thread_mutation, { threadId: thread_id })
        raise_on_errors(stringify(to_hash(response)))
        response
      end

      # Hides a comment behind GitHub's "Show comment" toggle, labelled as outdated.
      #
      # @param node_id [String] the GraphQL node ID of the comment to minimize
      # @raise [RuntimeError] if the GraphQL response contains top-level errors
      # @return [Object] the raw Octokit response
      def minimize_comment(node_id)
        response = post_graphql(minimize_comment_mutation, { subjectId: node_id })
        raise_on_errors(stringify(to_hash(response)))
        response
      end

      private

      # Octokit's #request strips a top-level :query key from Hash bodies (it
      # means URL params there), which would mangle a GraphQL query. Send a
      # pre-serialized JSON string so the whole payload reaches the body intact.
      def post_graphql(query, variables)
        @client.post('/graphql', { query: query, variables: variables }.to_json)
      end

      # GraphQL returns HTTP 200 even on errors, signalling them via a top-level
      # `errors` array. Surface them instead of silently reporting no threads.
      def raise_on_errors(body)
        return unless body.is_a?(Hash)

        errors = Array(body['errors'])
        return if errors.empty?

        messages = errors.map { |e| e.is_a?(Hash) ? e['message'] || e.to_s : e.to_s }.join('; ')
        raise "GitHub GraphQL request failed: #{messages}"
      end

      # Octokit parses responses into Sawyer::Resource objects keyed by symbols.
      # `#to_attrs` recursively converts the resource into a plain Hash; tolerate
      # nil and raw Hash responses (e.g. from stubbed clients in tests).
      def to_hash(response)
        return {} if response.nil?
        return response.to_attrs if response.respond_to?(:to_attrs)

        response
      end

      # Recursively converts symbol keys to strings so both this client and its
      # downstream consumers can traverse the result with string keys.
      def stringify(value)
        # Convert any nested Sawyer::Resource into a plain Hash before recursing
        # so string-key traversal (dig/[]) works all the way down.
        value = value.to_attrs if value.respond_to?(:to_attrs)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
        when Array
          value.map { |element| stringify(element) }
        else
          value
        end
      end

      def review_threads_query
        <<~GRAPHQL
          query($owner: String!, $repo: String!, $pr_number: Int!, $first: Int!) {
            repository(owner: $owner, name: $repo) {
              pullRequest(number: $pr_number) {
                reviewThreads(first: $first) {
                  nodes {
                    id
                    isResolved
                    isOutdated
                    line
                    path
                    resolvedBy { login }
                    comments(first: 1) {
                      nodes {
                        author { login }
                        body
                      }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
      end

      def resolve_thread_mutation
        <<~GRAPHQL
          mutation($threadId: ID!) {
            resolveReviewThread(input: { threadId: $threadId }) {
              thread { id }
            }
          }
        GRAPHQL
      end

      def minimize_comment_mutation
        <<~GRAPHQL
          mutation($subjectId: ID!) {
            minimizeComment(input: { subjectId: $subjectId, classifier: OUTDATED }) {
              minimizedComment { isMinimized }
            }
          }
        GRAPHQL
      end

      def thread_variables(owner, repo, pr_number)
        {
          owner: owner,
          repo: repo,
          pr_number: pr_number.to_i, # GraphQL Int! — coerce in case a string slips through
          first: THREAD_PAGE_SIZE
        }
      end
    end
  end
end
