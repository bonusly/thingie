# frozen_string_literal: true

module Thingie
  module GitHub
    # On a re-run of a pull request Thingie has already commented on, a model that reviews the
    # whole PR again will mention a different sample of issues each time, including about code
    # that has not changed. This holds those back unless they are severe. A finding about code
    # that is new or changed since the last review gets the normal bar.
    class RepeatBar
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
        kept = issues.select { |issue| keep?(issue, changed) }
        report_held_back(issues - kept)
        kept
      rescue Octokit::Error => e
        warn "Could not tell what changed since the last review, so every finding is posted — #{e.message}"
        issues
      end

      private

      # The commit Thingie last left a comment on; nil when it has not commented yet.
      def last_reviewed_commit
        ours = @client.pull_request_comments(@repo, @pr_number).select { |c| c.body.to_s.include?(@marker) }
        ours.max_by(&:created_at)&.original_commit_id
      end

      # Maps each file changed since `base` to the set of line numbers that were added or modified.
      def changed_lines(base, head)
        return {} if base == head

        @client.compare(@repo, base, head).files.to_h { |file| [file.filename, added_lines(file.patch.to_s)] }
      end

      def added_lines(patch)
        lines = Set.new
        new_line = nil
        patch.each_line do |raw|
          line = raw.chomp
          if (match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)/))
            new_line = match[1].to_i
          elsif new_line.nil? || line.start_with?('\\', '-')
            next
          else
            lines << new_line if line.start_with?('+')
            new_line += 1
          end
        end
        lines
      end

      def keep?(issue, changed)
        issue.severity.nil? || issue.severity <= @max_severity || touches_changed_lines?(issue, changed)
      end

      def touches_changed_lines?(issue, changed)
        added = changed[issue.file]
        return false unless added

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
