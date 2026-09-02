# frozen_string_literal: true

require 'octokit'

module Thingie
  module GitHub
    # Posts Thingie review results to a GitHub pull request. Resolves stale
    # Thingie review threads and collapses previous summary comments before
    # posting new feedback.
    class Commenter # rubocop:disable Metrics/ClassLength
      include Pacing

      REVIEW_COMMENT_MARKER = '<!-- thingie-review-comment -->'

      # Mirrors the default severity_scale in config/default.toml — used only
      # for human-facing labels in comments.
      SEVERITY_LABELS = { 1 => 'Critical', 2 => 'High', 3 => 'Medium', 4 => 'Low' }.freeze

      # Builds a commenter for a single pull request.
      #
      # @param token [String] the main GitHub token used for posting/updating comments
      # @param owner [String] the repository owner
      # @param repo [String] the repository name
      # @param pr_number [Integer] the pull request number
      # @param resolve_token [String, nil] optional PAT with write access, required to resolve
      #   review threads via GraphQL; falls back to `token` when absent (but resolution will
      #   fail for tokens that can't do it, e.g. `GITHUB_TOKEN`)
      def initialize(token:, owner:, repo:, pr_number:, resolve_token: nil)
        # auto_paginate so PRs with many files/comments aren't truncated to the
        # first page when validating diff lines or collapsing old summaries.
        @client = Octokit::Client.new(access_token: token, auto_paginate: true)
        # Resolving review threads (GraphQL resolveReviewThread) needs a
        # user-to-server token (a PAT). The Actions GITHUB_TOKEN and GitHub App
        # *installation* tokens can't and return "Resource not accessible by
        # integration". Use the resolve token when supplied, else the main token.
        # Treat blank as unset so an empty env var doesn't build an
        # unauthenticated client.
        @resolve_token = resolve_token.to_s.strip.empty? ? nil : resolve_token
        @owner = owner
        @repo = repo
        @pr_number = pr_number
        @comments_posted = 0
      end

      # Posts the review to the pull request: resolves stale Thingie threads,
      # collapses previous summary comments, then posts either a summary
      # comment (no issues) or inline comments plus an off-diff summary.
      #
      # @param summary [String] the human-readable review summary text
      # @param report [Thingie::Report] the completed review report
      # @return [void]
      def post_review(summary:, report:)
        pr = @client.pull_request("#{@owner}/#{@repo}", @pr_number)
        commit_id = pr.head.sha
        resolve_previous_threads(report.issues)
        collapse_previous_summaries
        if report.issues.empty?
          # Only post the overview comment when there's nothing to flag inline.
          post_summary_comment(summary)
        else
          off_diff = post_inline_comments(report.issues, commit_id)
          post_off_diff_comment(off_diff)
        end
        log_posting_tally(off_diff_count: off_diff.to_a.size)
      end

      # Comments posted inline on this run.
      #
      # @return [Integer] comments posted inline on this run
      attr_reader :comments_posted

      private

      # One warning per rejected comment tells you nothing about scale, and
      # scale is the signal: the run that broke special_sauce#26652 posted 53
      # comments in a burst. Emit a single line the log can be searched for
      # and a dashboard can eventually count.
      #
      # @param off_diff_count [Integer] findings that had no line in the diff
      # @return [void]
      def log_posting_tally(off_diff_count:)
        return if @comments_posted.zero? && off_diff_count.zero?

        warn "Thingie posted #{@comments_posted} inline comment(s); " \
             "#{off_diff_count} finding(s) had no line in the diff."
      end

      # Post one inline comment per affected line that falls inside the PR diff.
      # GitHub's review-comment API only accepts line-based comments on diff
      # lines; returns the issues that couldn't be posted inline (off-diff).
      def post_inline_comments(issues, commit_id)
        issues.reject { |issue| post_issue_inline?(issue, commit_id) }
      end

      # Issues outside the diff can't be inline comments. Collect them into a
      # single collapsed comment so the feedback isn't lost or noisy.
      def post_off_diff_comment(issues)
        return if issues.empty?

        rows = issues.map { |issue| off_diff_row(issue) }
        body = "<details><summary>#{issues.size} Thingie finding(s) outside this diff</summary>\n\n" \
               "#{rows.join("\n")}\n\n</details>\n\n#{Context::SUMMARY_MARKER}"
        with_pacing_retry('the off-diff findings comment') do
          @client.add_comment("#{@owner}/#{@repo}", @pr_number, body)
        end
      end

      def off_diff_row(issue)
        line = issue.affected_lines.first&.start_line
        location = line ? ":#{line}" : ''
        "- **#{severity_label(issue.severity)}** `#{issue.file}#{location}` — #{issue.title}"
      end

      def post_issue_inline?(issue, commit_id)
        issue.affected_lines.filter_map do |range|
          next unless range.start_line

          line = range.end_line || range.start_line
          next unless line_in_diff?(issue.file, line)

          create_inline_comment(issue, commit_id, line)
          true
        rescue Octokit::UnprocessableEntity => e
          warn "Could not post comment on #{issue.file}:#{line} — #{e.message}"
          nil
        end.any?
      end

      def create_inline_comment(issue, commit_id, line)
        with_pacing_retry("#{issue.file}:#{line}") do
          @client.create_pull_request_comment(
            "#{@owner}/#{@repo}",
            @pr_number,
            issue_body(issue),
            commit_id,
            issue.file,
            line, # Octokit 9: 6th positional is the new-side line number
            { side: 'RIGHT' }
          )
        end
        @comments_posted += 1
      end

      def post_summary_comment(summary)
        with_pacing_retry('the summary comment') do
          @client.add_comment("#{@owner}/#{@repo}", @pr_number, "#{summary}\n\n#{Context::SUMMARY_MARKER}")
        end
      end

      def severity_label(severity)
        SEVERITY_LABELS.fetch(severity, "Severity #{severity}")
      end

      def line_in_diff?(file, line)
        # When the diff can't be fetched, treat nothing as commentable so the
        # issue falls back to the summary rather than risking a 422 per line.
        return false unless commentable_lines

        commentable_lines.fetch(file, Set.new).include?(line)
      end

      # Maps each changed file to the set of new-side line numbers GitHub will
      # accept inline comments on (added and context lines within diff hunks).
      # Returns nil when the diff can't be fetched.
      def commentable_lines
        return @commentable_lines if defined?(@commentable_lines)

        files = @client.pull_request_files("#{@owner}/#{@repo}", @pr_number)
        @commentable_lines = files.each_with_object({}) do |file, hash|
          hash[file.filename] = new_side_lines(file.patch) if file.patch
        end
      rescue Octokit::Error => e
        warn "Could not fetch PR diff to validate comment lines — #{e.message}"
        @commentable_lines = nil
      end

      def new_side_lines(patch)
        lines = Set.new
        new_line = nil
        patch.each_line do |raw|
          line = raw.chomp
          if (match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)/))
            new_line = match[1].to_i
          # Skip hunk metadata, "\ No newline" markers, and deletions: none of
          # these advance or anchor a new-side line number.
          elsif new_line.nil? || line.start_with?('\\', '-')
            next
          else
            lines << new_line # added ('+') or context (' ') line
            new_line += 1
          end
        end
        lines
      end

      def issue_body(issue)
        tags = "Tags: #{issue.tags.join(', ')}" unless issue.tags.to_a.empty?
        [
          REVIEW_COMMENT_MARKER,
          "**[#{severity_label(issue.severity)}] #{issue.title}**",
          issue.details,
          tags
        ].compact.join("\n\n")
      end

      # Resolve Thingie's own review threads whose issue is no longer reported
      # (fixed) or whose anchor line is outdated. Threads are identified by the
      # REVIEW_COMMENT_MARKER in their first comment, so this works even with the
      # default Actions GITHUB_TOKEN (which can't read /user to learn the bot's
      # login).
      def resolve_previous_threads(current_issues)
        current_lines = current_issue_lines(current_issues)
        # Resolve each thread independently so one failure doesn't strand the
        # rest; tally failures with an explicit loop (not #count) to keep the
        # API side effects out of a query method.
        unresolved = 0
        fetch_review_threads.each do |thread|
          unresolved += 1 unless resolve_thread(thread, current_lines)
        end
        warn_thread_resolution_failure(unresolved) if unresolved.positive?
      rescue StandardError => e
        warn "Could not fetch previous review threads — #{e.message}"
      end

      def warn_thread_resolution_failure(count)
        message = @resolve_error&.message
        warn "Could not resolve #{count} previous review thread(s) — #{message}"
        return unless message.to_s.include?('not accessible')

        # Covers both "by integration" (GITHUB_TOKEN / App installation token)
        # and "by personal access token" (fine-grained PAT lacking access).
        warn 'resolveReviewThread needs a user token with write access. ' \
             'GITHUB_TOKEN and GitHub App installation tokens cannot; ' \
             'fine-grained PATs are unreliable and need org approval for write. ' \
             'Use a classic PAT with the `repo` scope (SSO-authorized if your ' \
             'org requires it) in --resolve-token / THINGIE_RESOLVE_TOKEN.'
      end

      def current_issue_lines(issues)
        issues.each_with_object({}) do |issue, hash|
          hash[issue.file] ||= []
          issue.affected_lines.each do |range|
            next unless range.start_line

            hash[issue.file] << (range.end_line || range.start_line)
          end
        end
      end

      def graphql_client
        @graphql_client ||= GraphqlClient.new(resolve_client)
      end

      # A separate Octokit client for GraphQL thread resolution when a resolve
      # token is configured; otherwise the main client.
      def resolve_client
        return @client unless @resolve_token

        Octokit::Client.new(access_token: @resolve_token, auto_paginate: true)
      end

      def fetch_review_threads
        graphql_client.review_threads(
          owner: @owner,
          repo: @repo,
          pr_number: @pr_number
        )
      end

      # Returns true when the thread needs no action or was resolved; false (and
      # records the error) when the resolve call itself failed.
      def resolve_thread(thread, current_lines)
        return true if thread['isResolved']
        return true unless thingie_thread?(thread)
        return true if line_still_reported?(thread, current_lines)

        graphql_client.resolve_thread(thread['id'])
        true
      rescue StandardError => e
        @resolve_error = e
        false
      end

      def thingie_thread?(thread)
        first_comment = thread.dig('comments', 'nodes', 0)
        first_comment && first_comment['body'].to_s.include?(REVIEW_COMMENT_MARKER)
      end

      def line_still_reported?(thread, current_lines)
        return false if thread['isOutdated']

        path = thread['path']
        line = thread['line']
        return false if path.nil? || line.nil?

        (current_lines[path] || []).include?(line)
      end

      def collapse_previous_summaries
        comments = @client.issue_comments("#{@owner}/#{@repo}", @pr_number)
        comments.each do |comment|
          next unless comment.body.include?(Context::SUMMARY_MARKER)

          @client.update_comment("#{@owner}/#{@repo}", comment.id, outdated_body(comment.body))
        rescue Octokit::Forbidden => e
          # Only the comment's author (our bot) can edit it; skip others.
          warn "Could not collapse previous summary ##{comment.id} — #{e.message}"
        end
      end

      def outdated_body(body)
        stripped = body.sub(Context::SUMMARY_MARKER, '')
        "<details><summary>Outdated Thingie summary</summary>\n\n#{stripped}\n\n</details>"
      end
    end
  end
end
