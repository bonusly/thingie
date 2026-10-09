# frozen_string_literal: true

require 'octokit'

module Thingie
  module GitHub
    # Posts Thingie review results to a GitHub pull request. Resolves stale
    # Thingie review threads and collapses previous summary comments before
    # posting new feedback.
    class Commenter # rubocop:disable Metrics/ClassLength
      REVIEW_COMMENT_MARKER = '<!-- thingie-review-comment -->'
      OUTDATED_PREFIX = '<details><summary>Outdated review'
      OPEN_FINDINGS_SHOWN = 5

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
      # @param duplicate_filter [Thingie::DuplicateFilter, nil] drops findings that repeat another
      #   finding or a comment that is still open; findings are all posted when absent
      # @param repeat_max_severity [Integer, nil] on a re-run, the least severe grade (1 = Critical) a new
      #   finding about code unchanged since the last review may have and still be posted; nil disables it
      def initialize(token:, owner:, repo:, pr_number:, resolve_token: nil, duplicate_filter: nil,
                     repeat_max_severity: nil)
        @duplicate_filter = duplicate_filter
        @repeat_max_severity = repeat_max_severity
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
        open_threads = resolve_previous_threads
        collapse_previous_summaries
        if report.issues.empty?
          post_summary_comment(rerun_summary(summary, open_threads))
        else
          new_issues = without_repeats(repeat_bar.call(report.issues, commit_id), open_threads)
          post_off_diff_comment(post_inline_comments(new_issues, commit_id))
          post_summary_comment(run_summary(new_issues.size, open_threads, commit_id))
        end
      end

      private

      # Post one inline comment per affected line that falls inside the PR diff.
      # GitHub's review-comment API only accepts line-based comments on diff
      # lines; returns the issues that couldn't be posted inline (off-diff). A
      # finding whose text is about another file is never put on a line, because
      # its line numbers belong to that other file.
      def post_inline_comments(issues, commit_id)
        issues.reject { |issue| issue.cited_other_file.nil? && post_issue_inline?(issue, commit_id) }
      end

      # The summary describes only this run. On a PR Thingie has reviewed before, "No changes recommended"
      # would read as if nothing had ever been flagged, so it says "No new changes recommended", or says
      # that earlier findings are still open when they are.
      def rerun_summary(summary, open_threads)
        return summary unless open_threads.any? || repeat_bar.reviewed_before?

        note = ReportRenderer::NO_NEW_CHANGES
        note = "#{note}\n\n#{open_findings_list(open_threads)}" if open_threads.any?
        return summary.sub(ReportRenderer::NO_CHANGES, note) if summary.include?(ReportRenderer::NO_CHANGES)

        "#{summary}\n\n#{note}"
      end

      # The short summary of a run that had findings. "No new changes recommended" when they were all repeats
      # or held back, so every push gets a visible result, and the earlier findings that are still open.
      def run_summary(posted, open_threads, commit_id)
        findings = posted == 1 ? 'finding' : 'findings'
        headline = posted.positive? ? "**⚠️ #{posted} new #{findings}, posted as review comments**" : ReportRenderer::NO_NEW_CHANGES
        parts = ["### Review of `#{commit_id.to_s[0, 7]}`", headline]
        parts << open_findings_list(open_threads) if open_threads.any?
        parts.join("\n\n")
      end

      # The findings from earlier runs that are still open, each with its severity and a link to its comment.
      def open_findings_list(open_threads)
        lines = open_threads.first(OPEN_FINDINGS_SHOWN).map { |thread| open_finding_line(thread) }
        extra = open_threads.size - OPEN_FINDINGS_SHOWN
        lines << "- and #{extra} more" if extra.positive?
        "**Still open from earlier reviews (#{open_threads.size}):**\n\n#{lines.join("\n")}"
      end

      def open_finding_line(thread)
        comment = thread.dig('comments', 'nodes', 0) || {}
        match = comment['body'].to_s.match(/\*\*\[(\w+)\] (.+?)\*\*/)
        severity, title = match ? match.captures : ['Finding', 'An earlier finding']
        label = comment['url'] ? "[#{title}](#{comment['url']})" : title
        "- **#{severity}:** #{label} (`#{thread['path']}`)"
      end

      def repeat_bar
        RepeatBar.new(client: @client, repo: "#{@owner}/#{@repo}", pr_number: @pr_number,
                      max_severity: @repeat_max_severity, marker: REVIEW_COMMENT_MARKER)
      end

      # Findings that repeat another finding or a comment that is still open are
      # dropped. If the check itself fails, everything is posted and the failure is
      # reported, so a broken check never hides a finding.
      def without_repeats(issues, open_threads)
        return issues unless @duplicate_filter

        @duplicate_filter.call(issues, open_threads.map { |thread| open_comment_for(thread) })
      rescue StandardError => e
        warn "Could not check for repeated findings, posting all of them — #{e.class}: #{e.message}"
        issues
      end

      def open_comment_for(thread)
        body = thread.dig('comments', 'nodes', 0, 'body').to_s.sub(REVIEW_COMMENT_MARKER, '')
        { file: thread['path'], line: thread['line'], text: body.sub(%r{<details>.*?</details>}m, '').strip }
      end

      # Issues outside the diff can't be inline comments. Collect them into a
      # single collapsed comment so the feedback isn't lost or noisy.
      def post_off_diff_comment(issues)
        return if issues.empty?

        rows = issues.map { |issue| off_diff_row(issue) }
        body = "<details><summary>#{issues.size} finding(s) outside this diff or about another file</summary>\n\n" \
               "#{rows.join("\n")}\n\n</details>\n\n#{Context::SUMMARY_MARKER}"
        @client.add_comment("#{@owner}/#{@repo}", @pr_number, body)
      end

      def off_diff_row(issue)
        cited = issue.cited_other_file
        line = issue.affected_lines.first&.start_line
        location = cited || [issue.file, line].compact.join(':')
        "- **#{severity_label(issue.severity)}** `#{location}` — #{issue.title}"
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

      def post_summary_comment(summary)
        body = summary.include?(Context::SUMMARY_MARKER) ? summary : "#{summary}\n\n#{Context::SUMMARY_MARKER}"
        @client.add_comment("#{@owner}/#{@repo}", @pr_number, body)
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
          hash[file.filename] = DiffLines.new_side(file.patch) if file.patch
        end
      rescue Octokit::Error => e
        warn "Could not fetch PR diff to validate comment lines — #{e.message}"
        @commentable_lines = nil
      end

      def issue_body(issue)
        tags = "Tags: #{issue.tags.join(', ')}" unless issue.tags.to_a.empty?
        [
          REVIEW_COMMENT_MARKER,
          "**[#{severity_label(issue.severity)}] #{issue.title}**",
          issue.details_markdown,
          issue.evidence_block,
          tags
        ].compact.join("\n\n")
      end

      # Resolve Thingie's own review threads whose anchor line is outdated, meaning the code it
      # commented on changed. A thread is never resolved just because the model did not repeat the
      # finding on a later run: it samples a different set of issues each time, and the code is
      # unchanged. Threads are identified by the REVIEW_COMMENT_MARKER in their first comment, so
      # this works even with the default Actions GITHUB_TOKEN (which can't read /user to learn the
      # bot's login). Returns the Thingie threads that are still open.
      def resolve_previous_threads
        # Resolve each thread independently so one failure doesn't strand the
        # rest; tally failures with an explicit loop (not #count) to keep the
        # API side effects out of a query method.
        unresolved = 0
        threads = fetch_review_threads.select { |thread| thingie_thread?(thread) }
        threads.each { |thread| unresolved += 1 unless resolve_thread(thread) }
        warn_thread_resolution_failure(unresolved) if unresolved.positive?
        threads.reject { |thread| thread['isResolved'] || thread['isOutdated'] }
      rescue StandardError => e
        warn "Could not fetch previous review threads — #{e.message}"
        []
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
      def resolve_thread(thread)
        return true if thread['isResolved'] || !thread['isOutdated']

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

      def collapse_previous_summaries
        comments = @client.issue_comments("#{@owner}/#{@repo}", @pr_number)
        comments.each do |comment|
          next unless comment.body.include?(Context::SUMMARY_MARKER)
          next if comment.body.start_with?(OUTDATED_PREFIX)

          @client.update_comment("#{@owner}/#{@repo}", comment.id, outdated_body(comment.body))
          minimize_comment(comment)
        rescue Octokit::Forbidden => e
          # Only the comment's author (our bot) can edit it; skip others.
          warn "Could not collapse previous summary ##{comment.id} — #{e.message}"
        end
      end

      # Collapsing alone still leaves a stack of "Outdated review" rows in the
      # thread; minimizing tucks each one behind GitHub's "Show comment" toggle.
      def minimize_comment(comment)
        graphql_client.minimize_comment(comment.node_id)
      rescue StandardError => e
        warn "Could not hide previous summary ##{comment.id} — #{e.message}"
      end

      def outdated_body(body)
        stripped = body.gsub(Context::SUMMARY_MARKER, '').strip
        sha = stripped[/Review of `(\h+)`/, 1]
        label = sha ? " of `#{sha}`" : ''
        "#{OUTDATED_PREFIX}#{label}</summary>\n\n#{stripped}\n\n</details>"
      end
    end
  end
end
