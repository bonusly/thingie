# frozen_string_literal: true

module Thingie
  module GitHub
    # On a re-run of a pull request Thingie has already commented on, a model that reviews the
    # whole PR again will mention a different sample of issues each time, including about code
    # that has not changed. This holds those back unless they are severe. A finding about code
    # that is new or changed since the last review gets the normal bar.
    class RepeatBar
      # GitHub's compare call lists at most this many files, so a longer change cannot be told apart.
      COMPARE_FILE_LIMIT = 300

      # Builds the bar for one pull request.
      #
      # @param client [Octokit::Client] the GitHub client
      # @param repo [String] the repository, as "owner/name"
      # @param pr_number [Integer] the pull request number
      # @param max_severity [Integer, nil] the least severe grade (1 = Critical) a finding about unchanged
      #   code may have and still be posted; nil disables the bar
      # @param marker [String] the marker that identifies Thingie's own review comments
      def initialize(client:, repo:, pr_number:, max_severity:, marker:)
        @client = client
        @repo = repo
        @pr_number = pr_number
        @max_severity = max_severity
        @marker = marker
      end

      # Drops the findings that are below the bar and about code unchanged since the last review.
      #
      # @param issues [Array<Thingie::Issue>] the findings about to be posted
      # @param head_sha [String] the commit being reviewed now
      # @return [Array<Thingie::Issue>] the findings to post; all of them on a first review or when the
      #   changes since the last review cannot be fetched
      def call(issues, head_sha)
        return issues unless @max_severity

        base = last_reviewed_commit
        return issues unless base

        changed = changed_lines(base, head_sha)
        return issues unless changed

        kept = issues.select { |issue| keep?(issue, changed) }
        report_held_back(issues - kept)
        kept
      rescue Octokit::Error => e
        warn "Could not tell what changed since the last review, so every finding is posted — #{e.message}"
        issues
      end

      private

      # The commit of Thingie's most recent review, from its inline comments or, when a run had no
      # inline findings, from the "Review of `sha`" heading of its summary comment (which a later
      # run collapses but keeps). Nil when Thingie has not reviewed the PR yet.
      def last_reviewed_commit
        (inline_reviews + summary_reviews).max_by(&:first)&.last
      end

      def inline_reviews
        @client.pull_request_comments(@repo, @pr_number)
               .select { |comment| comment.body.to_s.include?(@marker) }
               .map { |comment| [comment.created_at, comment.original_commit_id] }
      end

      def summary_reviews
        @client.issue_comments(@repo, @pr_number).filter_map do |comment|
          body = comment.body.to_s
          next unless body.include?(Context::SUMMARY_MARKER) || body.start_with?(Commenter::OUTDATED_PREFIX)

          sha = body[/Review of `(\h+)`/, 1]
          [comment.created_at, sha] if sha
        end
      end

      # Maps each file changed since `base` to the set of line numbers that were added or modified, or
      # to :unknown when GitHub left out the file's diff because it is too large or binary. Nil when the
      # change is too long for GitHub to list every file, so nothing can be said about any of them.
      def changed_lines(base, head)
        return {} if base == head

        files = @client.compare(@repo, base, head).files
        if files.size >= COMPARE_FILE_LIMIT
          warn "The change since the last review has #{COMPARE_FILE_LIMIT} or more files, so every finding is posted"
          return nil
        end

        files.to_h do |file|
          [file.filename, file.patch.nil? ? :unknown : DiffLines.new_side(file.patch, added_only: true)]
        end
      end

      def keep?(issue, changed)
        issue.severity.nil? || issue.severity <= @max_severity || touches_changed_lines?(issue, changed)
      end

      def touches_changed_lines?(issue, changed)
        added = changed[issue.file]
        return false unless added
        return true if added == :unknown

        issue.affected_lines.any? do |range|
          next false unless range.start_line

          (range.start_line..(range.end_line || range.start_line)).any? { |line| added.include?(line) }
        end
      end

      def report_held_back(held_back)
        return if held_back.empty?

        titles = held_back.map(&:title).join('; ')
        warn "Held back #{held_back.size} new finding(s) about code unchanged since the last review " \
             "(severity above #{@max_severity}): #{titles}"
      end
    end
  end
end
