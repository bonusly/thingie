# frozen_string_literal: true

require 'octokit'
require_relative 'linked_runs'

module Thingie
  module GitHub
    # Approves a pull request when GitHub Copilot's latest review approves the
    # PR's current commit and a configurable set of safety rules all pass.
    # Disabled unless approve.enabled is set in config. Reads happen on the main
    # token; the approval (and any dismissal) is attempted with the main token
    # first, then falls back to the resolve-token user (PAT) when that attempt
    # errors.
    class Approver # rubocop:disable Metrics/ClassLength
      APPROVAL_MARKER = '<!-- thingie-approval -->'
      # Marks the single upsert-able comment that explains why a PR was not
      # auto-approved, so re-runs update it in place instead of stacking comments.
      STATUS_MARKER = '<!-- thingie-approval-status -->'
      # Never auto-approve a PR that edits Thingie's own config — that's how
      # someone would weaken the approval rules to wave their change through.
      CONFIG_PATH = '.thingie/config.toml'
      # The login Copilot code review submits its reviews as. Logins ending in
      # [bot] are reserved for GitHub Apps, so no user account can post as it.
      COPILOT_LOGIN = 'copilot-pull-request-reviewer[bot]'
      DEFAULT_MAX_CHANGES = 500
      DEFAULT_SKIP_LABEL = 'thingie-skip-approve'

      Decision = Struct.new(:action, :reasons)

      # Builds an approver for a single pull request.
      #
      # @param token [String] the main GitHub token used for reads and the first approval attempt
      # @param owner [String] the repository owner
      # @param repo [String] the repository name
      # @param pr_number [Integer] the pull request number
      # @param config [Hash] the `approve` section of the resolved configuration
      # @param resolve_token [String, nil] optional PAT used as a fallback for actions the
      #   main token can't perform (e.g. team membership reads, dismissals)
      def initialize(token:, owner:, repo:, pr_number:, config: {}, resolve_token: nil)
        # Reads and the first approval attempt use the main token; the PAT is the
        # fallback when that attempt errors. An empty env var is treated as unset.
        resolve_token = nil if resolve_token.to_s.strip.empty?
        @client = Octokit::Client.new(access_token: token, auto_paginate: true)
        @resolve_client = resolve_token && Octokit::Client.new(access_token: resolve_token, auto_paginate: true)
        @owner = owner
        @repo = repo
        @pr_number = pr_number
        @config = config || {}
      end

      # Evaluate the rules and approve / dismiss accordingly. Never raises into
      # the run. Returns the Decision so the caller can emit it as a stats
      # event; nil when an error short-circuited the evaluation.
      #
      # @return [Thingie::GitHub::Approver::Decision, nil] the decision, or nil on failure
      def run
        pr = @client.pull_request(slug, @pr_number)
        decision = decide(pr)
        log(decision)
        apply(pr, decision)
        sync_status_comment(pr, decision)
        decision
      rescue StandardError => e
        warn "Auto-approval skipped — #{e.message}"
        nil
      end

      private

      def slug
        "#{@owner}/#{@repo}"
      end

      def max_changes
        @config.fetch('max_changes', DEFAULT_MAX_CHANGES)
      end

      def skip_label
        @config.fetch('skip_label', DEFAULT_SKIP_LABEL)
      end

      def dry_run?
        @config['dry_run'] ? true : false
      end

      # "org/team-slug" the PR author must belong to for auto-approval. Blank
      # disables team gating.
      def approval_team
        @config['approval_team'].to_s.strip
      end

      # Bot logins (e.g. "loop-de-loops[bot]") eligible alongside approval_team
      # members: a GitHub App can't join a team, so it's named here instead.
      def approval_bots
        Array(@config['approval_bots']).map { |login| login.to_s.strip }.reject(&:empty?)
      end

      # Skip (leave existing approvals alone) for intentional non-approvals;
      # block (dismiss any stale approval) when a rule fails.
      def decide(pr)
        return skip("skip label '#{skip_label}' present") if labelled_skip?(pr)
        return skip('PR is a draft') if pr.draft
        return skip('approving identity is the PR author') if self_approval?(pr)
        return skip("PR author is not in the #{approval_team} team") if outside_approval_team?(pr)

        reasons = block_reasons(pr)
        reasons.empty? ? approve : blocked(reasons)
      end

      def block_reasons(pr)
        reasons = []
        reasons << copilot_reason(pr)
        reasons << "#{CONFIG_PATH} was changed in this PR" if config_changed?
        reasons << 'a protected path was changed in this PR' if protected_path_changed?
        reasons << change_size_reason(pr) if too_many_changes?(pr)
        reasons << obfuscation_reason(pr) if obfuscated?(pr)
        reasons << unscanned_reason(pr) if unscanned_files(pr).any?
        reasons << 'a human reviewer requested changes' if human_requested_changes?
        reasons.concat(off_main_runs(pr))
        reasons.compact
      end

      # Copilot's most recent review must be an approval of the exact commit
      # being approved. Copilot submits "Changes recommended" as a COMMENTED
      # review, and a push leaves its earlier review on an older commit, so
      # both block until Copilot approves the new head.
      def copilot_reason(pr)
        review = latest_copilot_review
        return 'Copilot has not reviewed this PR' if review.nil?
        return 'Copilot has not reviewed the latest commit yet' unless review.commit_id == pr.head.sha
        return if review.state == 'APPROVED'

        "Copilot did not recommend approval (its latest review is #{review.state.downcase.tr('_', ' ')})"
      end

      def latest_copilot_review
        reviews.select { |review| copilot?(review) }.last
      end

      def copilot?(review)
        review.user&.login == COPILOT_LOGIN && review.user&.type == 'Bot'
      end

      # The reviews as they stood when the decision was made, oldest first.
      def reviews
        @reviews ||= @client.pull_request_reviews(slug, @pr_number)
      end

      # "owner/name" repositories whose Actions runs, linked from the PR, must have run from
      # that repository's default branch.
      def main_branch_run_repos
        Array(@config['main_branch_run_repos']).map(&:to_s).reject(&:empty?)
      end

      def off_main_runs(pr)
        linked_runs(pr)&.off_branch.to_a
      end

      # Only the description and the author's comments count: fixit's summary comment, which links
      # the run that opened the PR, is the author's, and a reviewer citing a test run of their own
      # shouldn't block. A run that can't be read doesn't block; the approval says it wasn't checked.
      def linked_runs(pr)
        return if main_branch_run_repos.empty?

        @linked_runs ||= begin
          texts, unread = linked_run_texts(pr)
          result = LinkedRuns.new(clients: [@client, @resolve_client].compact, repos: main_branch_run_repos)
                             .check(texts)
          result.unchecked.unshift(unread) if unread
          result
        end
      end

      def linked_run_texts(pr)
        comments = @client.issue_comments(slug, @pr_number).select { |comment| comment.user&.login == pr.user&.login }
        [[pr.body, *comments.map(&:body)], nil]
      rescue Octokit::Error, Faraday::Error => e
        warn "Could not read PR comments for linked runs — #{e.message}"
        [[pr.body], 'runs linked from PR comments (comments could not be read)']
      end

      # Obfuscation is a hard block: encoded or dynamically-constructed code
      # must always get human review, the same fail-safe posture as
      # config/protected-path changes.
      def obfuscated?(pr)
        obfuscation_findings(pr).any?
      end

      def obfuscation_reason(pr)
        files = obfuscation_findings(pr).map(&:file).uniq
        "obfuscated code detected in #{files.join(', ')}"
      end

      # A file that couldn't be read wasn't scanned, so it fails safe.
      def unscanned_reason(pr)
        files = unscanned_files(pr)
        shown = files.first(3)
        shown << '...' if files.size > shown.size
        "#{files.size} file(s) could not be read to scan for obfuscated code (#{shown.join(', ')})"
      end

      def obfuscation_findings(pr)
        @obfuscation_findings ||= ObfuscationDetector.new(head_contents(pr).compact).call
      end

      def unscanned_files(pr)
        head_contents(pr).select { |_file, content| content.nil? }.keys
      end

      # The full content of every changed file at the PR's head commit, read
      # from the API so the PR's code is never checked out. A deleted file has
      # nothing to scan and a binary file is mapped to "" (scanned as empty);
      # a file that can't be read is nil.
      def head_contents(pr)
        @head_contents ||= pr_files.reject { |file| file.status == 'removed' }.to_h do |file|
          [file.filename, file_content(file.filename, pr.head.sha)]
        end
      end

      def file_content(path, sha)
        raw = @client.contents(slug, path: path, ref: sha, accept: 'application/vnd.github.raw').to_s
        raw.include?("\0") ? '' : raw.dup.force_encoding(Encoding::UTF_8).scrub
      rescue Octokit::Error, Faraday::Error => e
        warn "Could not read #{path} at #{sha} — #{e.message}"
        nil
      end

      def approve
        Decision.new(:approve, [])
      end

      def blocked(reasons)
        Decision.new(:block, reasons)
      end

      def skip(reason)
        Decision.new(:skip, Array(reason))
      end

      def labelled_skip?(pr)
        Array(pr.labels).any? { |label| label_name(label) == skip_label }
      end

      def label_name(label)
        label.respond_to?(:name) ? label.name : label['name']
      end

      def self_approval?(pr)
        me = approving_login
        !me.nil? && pr.user&.login == me
      end

      # True when team gating is configured and the PR author is not an active
      # member. Skips (not blocks) so a human's existing approval is left intact.
      def outside_approval_team?(pr)
        return false if approval_team.empty?

        !approval_bot?(pr) && !author_on_approval_team?(pr)
      end

      def approval_bot?(pr)
        approval_bots.include?(pr.user&.login)
      end

      def author_on_approval_team?(pr)
        login = pr.user&.login
        org, team_slug = approval_team.split('/', 2)
        return false if login.nil? || org.to_s.empty? || team_slug.to_s.empty?

        team_membership_active?(org, team_slug, login)
      end

      # Reading org team membership needs read:org, which the Actions
      # GITHUB_TOKEN usually lacks — try the resolve-token PAT first, then the
      # main token. A 404 is a definitive "not a member"; any other error leaves
      # membership undetermined, which fails safe (treated as not eligible).
      def team_membership_active?(org, team_slug, login)
        path = "/orgs/#{org}/teams/#{team_slug}/memberships/#{login}"
        [@resolve_client, @client].compact.each do |client|
          return client.get(path)[:state] == 'active'
        rescue Octokit::NotFound
          return false
        rescue Octokit::Error
          next
        end
        false
      end

      # Tokens that can't read /user (Actions GITHUB_TOKEN, App installation
      # tokens) leave the identity unknown; the GitHub 422 on the approve call is
      # the backstop in that case.
      def approving_login
        @client.user.login
      rescue Octokit::Error
        nil
      end

      def config_changed?
        changed_files.include?(CONFIG_PATH)
      end

      # Block when any changed file matches a configured protected glob (e.g.
      # billing code, sensitive config).
      def protected_path_changed?
        patterns = Array(@config['protected_paths'])
        return false if patterns.empty?

        changed_files.any? do |file|
          patterns.any? { |pattern| File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end
      end

      def changed_files
        pr_files.map(&:filename)
      end

      def pr_files
        @pr_files ||= @client.pull_request_files(slug, @pr_number)
      end

      # Fail safe: an unknown size (nil) blocks approval so a PR whose size
      # GitHub doesn't report still requires a human, rather than bypassing the
      # ceiling.
      def too_many_changes?(pr)
        count = change_count(pr)
        count.nil? || count > max_changes
      end

      def change_size_reason(pr)
        count = change_count(pr)
        return 'PR change size is unknown' if count.nil?

        "PR has #{count} changes (max #{max_changes})"
      end

      # nil when GitHub doesn't report the size.
      def change_count(pr)
        additions = pr.additions
        deletions = pr.deletions
        return nil if additions.nil? || deletions.nil?

        additions + deletions
      end

      def apply(pr, decision)
        return if dry_run?

        case decision.action
        when :approve
          # Drop any approval left over from an earlier commit before approving
          # the current head, so an approval never outlives the exact commit it
          # was granted for.
          dismiss(superseded_approvals(pr.head.sha))
          ensure_approved(pr)
        when :block
          dismiss(thingie_approvals)
        end
      end

      def ensure_approved(pr)
        return if approved_for?(pr.head.sha)

        # Main token first, PAT fallback. The PAT fallback covers the common
        # case where the main token (GITHUB_TOKEN) lacks approval rights.
        attempt_with_fallback('approve PR') do |client|
          client.create_pull_request_review(slug, @pr_number, event: 'APPROVE', commit_id: pr.head.sha,
                                                              body: approval_body(pr))
        end
      end

      def approval_body(pr)
        [APPROVAL_MARKER, details_section(pr)].join("\n\n")
      end

      def dry_run_approval_body(pr)
        [
          STATUS_MARKER,
          '_Dry run — no approval action was taken._',
          'Thingie would automatically approve this PR: all auto-approval rules passed.',
          details_section(pr)
        ].join("\n\n")
      end

      def listed(title, lines)
        "**#{title}**\n#{lines.map { |line| "- #{line}" }.join("\n")}"
      end

      # Deterministic list of the gates that were satisfied for this approval.
      def passed_rules_section(pr)
        checks = ['Copilot approved the current commit', 'No Thingie config change', 'No protected paths changed']
        checks << change_size_check(pr)
        checks << 'No obfuscated code in the changed files'
        checks << 'No human reviewer requested changes'
        checks << 'No linked workflow run came from off the default branch' if linked_runs(pr)&.unchecked&.empty?
        checks << author_check(pr) unless approval_team.empty?
        listed('Checks passed', checks)
      end

      # Other required checks Thingie does not evaluate (e.g. a security pass, the
      # test suite) that still gate merge. Configured via approve.external_checks
      # so a repo can make clear that Thingie's approval isn't the only gate.
      def external_checks_section
        checks = Array(@config['external_checks']).map(&:to_s).reject(&:empty?)
        return nil if checks.empty?

        listed('Checks not evaluated', checks)
      end

      def author_check(pr)
        return "Author #{pr.user.login} is an approved bot" if approval_bot?(pr)

        "Author is a member of #{approval_team}"
      end

      # Linked runs Thingie couldn't read, so a reader knows that check didn't cover them.
      def unchecked_runs_section(pr)
        unchecked = linked_runs(pr)&.unchecked.to_a
        return nil if unchecked.empty?

        listed('Linked runs not checked (no token could read them)', unchecked)
      end

      def change_size_check(pr)
        count = change_count(pr)
        count.nil? ? 'Change size within limit' : "Change size within limit (#{count} of max #{max_changes})"
      end

      def details_section(pr)
        parts = [passed_rules_section(pr), unchecked_runs_section(pr), external_checks_section].compact
        "#{version_line}\n\n<details><summary>Thingie details</summary>\n\n#{parts.join("\n\n")}\n\n</details>"
      end

      def version_line
        "_Thingie v#{Thingie::VERSION}_"
      end

      # Prior Thingie approvals granted for a commit other than the current head.
      # A new push supersedes them, so they must not keep counting.
      def superseded_approvals(head_sha)
        thingie_approvals.reject { |review| review.commit_id == head_sha }
      end

      def dismiss(reviews)
        reviews.each do |review|
          attempt_with_fallback("dismiss stale approval ##{review.id}") do |client|
            client.dismiss_pull_request_review(slug, @pr_number, review.id,
                                               'Thingie auto-approval no longer applies.')
          end
        end
      end

      # Try each write client in order; return on the first success. If they all
      # fail, warn with the last error rather than failing the run.
      def attempt_with_fallback(action)
        last_error = nil
        [@client, @resolve_client].compact.each do |client|
          return yield(client)
        rescue Octokit::Error => e
          last_error = e
        end
        warn "Could not #{action} — #{last_error&.message}"
      end

      def approved_for?(sha)
        thingie_approvals.any? { |review| review.commit_id == sha }
      end

      # Read fresh rather than from {#reviews}: approvals are dismissed and
      # granted during {#apply}.
      def thingie_approvals
        @client.pull_request_reviews(slug, @pr_number).select do |review|
          review.state == 'APPROVED' && review.body.to_s.include?(APPROVAL_MARKER)
        end
      end

      # Block when a human reviewer's current review is CHANGES_REQUESTED — a
      # human's active pushback must never be waved through. Undeterminable state
      # fails safe (block), consistent with the other fail-safe gates.
      def human_requested_changes?
        latest_human_review_states.value?('CHANGES_REQUESTED')
      rescue Octokit::Error
        true
      end

      # Each human reviewer's most recent approval-affecting review state, so a
      # later approval or dismissal supersedes an earlier CHANGES_REQUESTED.
      # Thingie's and Copilot's reviews are ignored; COMMENTED/PENDING reviews
      # don't change a reviewer's state and are skipped.
      def latest_human_review_states
        reviews.each_with_object({}) do |review, states|
          next if review.body.to_s.include?(APPROVAL_MARKER) || copilot?(review)
          next unless %w[APPROVED CHANGES_REQUESTED DISMISSED].include?(review.state)

          login = review.user&.login
          states[login] = review.state unless login.nil?
        end
      end

      def log(decision)
        prefix = dry_run? ? '[dry-run] ' : ''
        if decision.action == :approve
          warn "#{prefix}Thingie auto-approval: approving PR ##{@pr_number}."
        else
          warn "#{prefix}Thingie auto-approval: #{decision.action} — #{decision.reasons.join('; ')}."
        end
      end

      # Surface the decision on the PR itself, not just in the workflow log.
      # Blocked or skipped decisions upsert a single status comment explaining
      # why. A real approval removes any stale comment; a dry-run approval
      # instead posts the approval details without taking approval action.
      # Never raises into the run.
      def sync_status_comment(pr, decision)
        existing = status_comment
        if decision.action == :approve && dry_run?
          upsert_status_comment(existing, dry_run_approval_body(pr))
        elsif decision.action == :approve
          remove_status_comment(existing) if existing
        else
          upsert_status_comment(existing, status_body(decision))
        end
      rescue Octokit::Error => e
        warn "Could not post auto-approval status comment — #{e.message}"
      end

      def status_comment
        @client.issue_comments(slug, @pr_number).find { |comment| comment.body.to_s.include?(STATUS_MARKER) }
      end

      def status_body(decision)
        blocked = decision.action == :block
        headline = blocked ? 'Thingie did not auto-approve this PR:' : 'Thingie auto-approval skipped:'
        reasons = decision.reasons.map { |reason| "- #{reason}" }.join("\n")
        parts = [STATUS_MARKER]
        parts << '_Dry run — no approval action was taken._' if dry_run?
        parts << "**#{headline}**"
        parts << reasons
        parts << version_line
        parts.join("\n\n")
      end

      def upsert_status_comment(existing, body)
        if existing
          attempt_with_fallback("update approval status comment ##{existing.id}") do |client|
            client.update_comment(slug, existing.id, body)
          end
        else
          attempt_with_fallback('post approval status comment') do |client|
            client.add_comment(slug, @pr_number, body)
          end
        end
      end

      def remove_status_comment(existing)
        attempt_with_fallback("remove approval status comment ##{existing.id}") do |client|
          client.delete_comment(slug, existing.id)
        end
      end
    end
  end
end
