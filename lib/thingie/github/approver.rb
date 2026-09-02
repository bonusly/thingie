# frozen_string_literal: true

require 'octokit'
require_relative 'commenter' # SEVERITY_BY_LABEL is built from Commenter::SEVERITY_LABELS at load time
require_relative 'graphql_client'

module Thingie
  module GitHub
    # Optionally approves a pull request when a configurable set of safety rules
    # all pass. Runs after Commenter#post_review and is disabled unless
    # approve.enabled is set in config. Reads happen on the main token; the
    # approval (and any dismissal) is attempted with the main token first, then
    # falls back to the resolve-token user (PAT) when that attempt errors.
    class Approver # rubocop:disable Metrics/ClassLength
      APPROVAL_MARKER = '<!-- thingie-approval -->'
      # Marks the single upsert-able comment that explains why a PR was not
      # auto-approved, so re-runs update it in place instead of stacking comments.
      STATUS_MARKER = '<!-- thingie-approval-status -->'
      # Never auto-approve a PR that edits Thingie's own config — that's how
      # someone would weaken the approval rules to wave their change through.
      CONFIG_PATH = '.thingie/config.toml'
      DEFAULT_MAX_CHANGES = 500
      DEFAULT_MAX_SEVERITY = 3
      DEFAULT_SKIP_LABEL = 'thingie-skip-approve'

      # Inverse of Commenter::SEVERITY_LABELS, to read a thread's severity back
      # out of the comment body Thingie wrote (e.g. "[Critical]").
      SEVERITY_BY_LABEL = Commenter::SEVERITY_LABELS.invert.freeze

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
      # @param llm_client [Thingie::LlmClient, nil] optional client used only for the
      #   informational risk assessment in the approval comment
      # @param review_summary [String, nil] the review's summary text, included in the risk prompt
      def initialize(token:, owner:, repo:, pr_number:, config: {}, resolve_token: nil,
                     llm_client: nil, review_summary: nil)
        # Reads and the first approval attempt use the main token; the PAT is the
        # fallback when that attempt errors. An empty env var is treated as unset.
        resolve_token = nil if resolve_token.to_s.strip.empty?
        @client = Octokit::Client.new(access_token: token, auto_paginate: true, middleware: Pacing.middleware)
        @resolve_client = resolve_token && Octokit::Client.new(access_token: resolve_token, auto_paginate: true,
                                                               middleware: Pacing.middleware)
        @owner = owner
        @repo = repo
        @pr_number = pr_number
        @config = config || {}
        # Optional: used only to add an informational risk assessment to the
        # approval comment. Absent client/summary just omits that section.
        @llm_client = llm_client
        @review_summary = review_summary.to_s
      end

      # Dismiss all existing Thingie approvals on this PR before a new review
      # begins, so a stale approval from a prior run never outlives the review
      # that produced it. The new run will re-approve if the rules still pass.
      # Never raises: a dismissal failure must not block the review.
      #
      # @return [void]
      def dismiss_existing_approvals
        return if dry_run?

        dismiss(thingie_approvals)
      rescue StandardError => e
        warn "Could not dismiss existing approvals — #{e.message}"
      end

      # Evaluate the rules and approve / dismiss accordingly. Never raises into
      # the run: a failure here must not fail the review that already posted.
      # Returns the Decision so the caller can emit it as a stats event; nil
      # when an error short-circuited the evaluation.
      #
      # @param report [Thingie::Report] the completed review report
      # @param review_posted [Boolean] whether the review reached the PR. False blocks:
      #   findings a reviewer cannot see must not be approved past.
      # @return [Thingie::GitHub::Approver::Decision, nil] the decision, or nil on failure
      def run(report, review_posted: true)
        @review_posted = review_posted
        pr = @client.pull_request(slug, @pr_number)
        decision = decide(pr, report)
        log(decision)
        apply_decision(pr, decision, report)
        decision
      rescue StandardError => e
        warn "Auto-approval skipped — #{e.message}"
        nil
      end

      private

      # Applies the already-computed decision and syncs the status comment.
      # A failure here must not discard `decision` itself: it's the caller's
      # only route to the approval.decided stats event, and by this point the
      # rule evaluation that produced it already succeeded. `apply`'s own
      # dismiss paths read thingie_approvals / superseded_approvals directly
      # (unprotected — they run before attempt_with_fallback's own rescue is
      # even reached), so on the paced clients this class uses, a request
      # here can still raise Pacing::Throttled straight through to here.
      def apply_decision(pr, decision, report)
        apply(pr, decision, report)
        sync_status_comment(pr, decision, report)
      rescue Octokit::Error, Pacing::Throttled => e
        warn "Could not fully apply the #{decision.action} decision — #{e.message}"
      end

      def slug
        "#{@owner}/#{@repo}"
      end

      def max_changes
        @config.fetch('max_changes', DEFAULT_MAX_CHANGES)
      end

      def max_severity
        @config.fetch('max_severity', DEFAULT_MAX_SEVERITY)
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

      # Skip (leave existing approvals alone) for intentional non-approvals;
      # block (dismiss any stale approval) when a rule fails.
      def decide(pr, report)
        return skip("skip label '#{skip_label}' present") if labelled_skip?(pr)
        return skip('PR is a draft') if pr.draft
        return skip('approving identity is the PR author') if self_approval?(pr)
        return skip("PR author is not in the #{approval_team} team") if outside_approval_team?(pr)

        reasons = block_reasons(pr, report)
        reasons.empty? ? approve : blocked(reasons)
      end

      def block_reasons(pr, report)
        threads = thingie_threads
        reasons = []
        reasons << incomplete_review_reason(report) if report.unreviewed_files.to_a.any?
        reasons << 'the review could not be posted to this PR' unless @review_posted
        reasons << "#{CONFIG_PATH} was changed in this PR" if config_changed?
        reasons << 'a protected path was changed in this PR' if protected_path_changed?
        reasons << change_size_reason(pr) if too_many_changes?(pr)
        reasons << 'new findings at or above the approval severity threshold' if current_issues?(report)
        reasons << obfuscation_reason(report) if obfuscated?(report)
        reasons << 'unresolved Thingie findings remain' if unresolved?(threads)
        reasons << 'Thingie findings were resolved by the author or a contributor' if self_resolved?(threads, pr)
        reasons << 'a human reviewer requested changes' if human_requested_changes?
        reasons.concat(undetermined_reasons)
      end

      # Reasons for state decide() could not read at all, as opposed to state
      # it read and evaluated. changed_files, thingie_threads and
      # insider_logins have no local rescue of their own — a Pacing::Throttled
      # from any of them would otherwise reach run's outer rescue and discard
      # the whole decision, the same "no decision anywhere" failure the rest
      # of this PR closes. Failing safe here can't reuse config_changed?'s or
      # protected_path_changed?'s own true/false, since returning [] from
      # changed_files would make both silently read as "nothing changed" —
      # the opposite of fail-safe — so each gets its own flag and reason
      # instead of forcing a specific rule's message to lie about what it
      # found.
      def undetermined_reasons
        [
          ('could not determine which files changed in this PR' if @changed_files_undetermined),
          ('could not determine Thingie review thread state' if @threads_undetermined),
          ('could not determine who authored or committed to this PR' if @insiders_undetermined)
        ].compact
      end

      # A run that could not read a verdict for every changed file has not
      # cleared those files; it only failed to look at them. Approving on it
      # would treat "we did not see anything" as "there is nothing there".
      def incomplete_review_reason(report)
        files = report.unreviewed_files.to_a
        "the review did not cover #{files.size} changed file(s): #{files.join(', ')}"
      end

      # Obfuscation findings are a hard block regardless of [approve] max_severity:
      # encoded or dynamically-constructed code must always get human review, the
      # same fail-safe posture as config/protected-path changes. Catches both
      # scanner findings from this run and LLM findings that carried the tag.
      def obfuscated?(report)
        report.issues.any? { |issue| issue.tags.to_a.include?('obfuscation') }
      end

      def obfuscation_reason(report)
        files = report.issues
                      .select { |issue| issue.tags.to_a.include?('obfuscation') }
                      .map(&:file).uniq
        "obfuscated code detected in #{files.join(', ')}"
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

        !author_on_approval_team?(pr)
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
        rescue Octokit::Error, Pacing::Throttled
          next
        end
        false
      end

      # Tokens that can't read /user (Actions GITHUB_TOKEN, App installation
      # tokens) leave the identity unknown; the GitHub 422 on the approve call is
      # the backstop in that case.
      def approving_login
        @client.user.login
      rescue Octokit::Error, Pacing::Throttled
        nil
      end

      def config_changed?
        changed_files.include?(CONFIG_PATH)
      end

      # Block when any changed file matches a configured protected glob (e.g.
      # billing code, sensitive config) — same matching as exclude_files.
      def protected_path_changed?
        patterns = Array(@config['protected_paths'])
        return false if patterns.empty?

        changed_files.any? do |file|
          patterns.any? { |pattern| File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end
      end

      def changed_files
        return @changed_files if defined?(@changed_files)

        @changed_files = @client.pull_request_files(slug, @pr_number).map(&:filename)
      rescue Octokit::Error, Pacing::Throttled
        @changed_files_undetermined = true
        @changed_files = []
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

      def current_issues?(report)
        report.issues.any? { |issue| qualifying?(issue.severity) }
      end

      def unresolved?(threads)
        threads.any? { |thread| !thread['isResolved'] && qualifying?(thread_severity(thread)) }
      end

      # Every qualifying Thingie thread that's resolved must have been resolved by
      # someone who is neither the PR author nor a contributor. Unknown resolver
      # (e.g. deleted account) fails safe.
      def self_resolved?(threads, pr)
        insiders = insider_logins(pr)
        threads.any? do |thread|
          next false unless thread['isResolved'] && qualifying?(thread_severity(thread))

          resolver = thread.dig('resolvedBy', 'login')
          resolver.nil? || insiders.include?(resolver)
        end
      end

      # PR author plus everyone who authored or committed code in the PR. Does
      # not cover Co-authored-by trailers (not real commit identities).
      def insider_logins(pr)
        logins = [pr.user&.login]
        @client.pull_request_commits(slug, @pr_number).each do |commit|
          logins << commit.author&.login
          logins << commit.committer&.login
        end
        logins.compact.uniq
      rescue Octokit::Error, Pacing::Throttled
        @insiders_undetermined = true
        [pr.user&.login].compact
      end

      # Treat unknown severity as qualifying so an unparseable thread fails safe.
      # For findings from this run, `report.issues` already reflects any critic
      # severity override (Verifier#call applies it before the report is built),
      # so a downgrade automatically stops blocking approval with no extra
      # plumbing here — this method never sees the pre-critic grade.
      def qualifying?(severity)
        severity.nil? || severity <= max_severity
      end

      def thingie_threads
        GraphqlClient.new(@client)
                     .review_threads(owner: @owner, repo: @repo, pr_number: @pr_number)
                     .select { |thread| thingie_thread?(thread) }
      rescue Octokit::Error, Pacing::Throttled
        @threads_undetermined = true
        []
      end

      def thingie_thread?(thread)
        thread.dig('comments', 'nodes', 0, 'body').to_s.include?(Commenter::REVIEW_COMMENT_MARKER)
      end

      def thread_severity(thread)
        body = thread.dig('comments', 'nodes', 0, 'body').to_s
        label = body[/\[([A-Za-z]+)\]/, 1]
        SEVERITY_BY_LABEL[label]
      end

      def apply(pr, decision, report)
        return if dry_run?

        case decision.action
        when :approve
          # Drop any approval left over from an earlier commit before approving
          # the current head, so an approval never outlives the exact commit it
          # was granted for.
          dismiss(superseded_approvals(pr.head.sha))
          ensure_approved(pr, report)
        when :block
          dismiss(thingie_approvals)
        end
      end

      def ensure_approved(pr, report)
        return if approved_for?(pr.head.sha)

        # Main token first, PAT fallback. The PAT fallback covers the common
        # case where the main token (GITHUB_TOKEN) lacks approval rights.
        attempt_with_fallback('approve PR') do |client|
          client.create_pull_request_review(slug, @pr_number, event: 'APPROVE', body: approval_body(pr, report))
        end
      end

      def approval_body(pr, report)
        [
          APPROVAL_MARKER,
          'Approved automatically by Thingie: all auto-approval rules passed.',
          *approval_details(pr, report)
        ].compact.join("\n\n")
      end

      def dry_run_approval_body(pr, report)
        [
          STATUS_MARKER,
          '_Dry run — no approval action was taken._',
          'Thingie would automatically approve this PR: all auto-approval rules passed.',
          *approval_details(pr, report)
        ].compact.join("\n\n")
      end

      def approval_details(pr, report)
        [
          passed_rules_section(pr),
          external_checks_section,
          risk_assessment_section(pr, report),
          details_section(report)
        ]
      end

      # Deterministic list of the gates that were satisfied for this approval.
      def passed_rules_section(pr)
        checks = ['No Thingie config change', 'No protected paths changed']
        checks << change_size_check(pr)
        checks << "No findings at or above #{severity_label(max_severity)} (#{max_severity})"
        checks << 'No unresolved Thingie findings'
        checks << 'No findings resolved by the PR author or a contributor'
        checks << 'No human reviewer requested changes'
        checks << "Author is a member of #{approval_team}" unless approval_team.empty?
        "**Checks passed**\n\n#{checks.map { |c| "- #{c}" }.join("\n")}"
      end

      def severity_label(severity)
        Commenter::SEVERITY_LABELS.fetch(severity, "severity #{severity}")
      end

      # Other required checks Thingie does not evaluate (e.g. a security pass, the
      # test suite) that still gate merge. Configured via approve.external_checks
      # so a repo can make clear that Thingie's approval isn't the only gate.
      def external_checks_section
        checks = Array(@config['external_checks']).map(&:to_s).reject(&:empty?)
        return nil if checks.empty?

        list = checks.map { |c| "- #{c}" }.join("\n")
        "**Other checks that must pass before merge** (not evaluated by Thingie)\n\n#{list}"
      end

      def change_size_check(pr)
        count = change_count(pr)
        count.nil? ? 'Change size within limit' : "Change size within limit (#{count} of max #{max_changes})"
      end

      # Informational only: an LLM risk level + summary. Omitted when no LLM
      # client is configured or the call fails — it must never block an approval
      # the deterministic rules already granted.
      def risk_assessment_section(pr, report)
        return nil unless @llm_client

        content = risk_assessment(pr, report)
        return nil if content.nil?

        level = content['risk_level'] || content[:risk_level]
        summary = content['summary'] || content[:summary]
        return nil if level.to_s.strip.empty? || summary.to_s.strip.empty?

        "**Risk assessment: #{level}**\n\n#{summary}"
      rescue StandardError => e
        warn "Risk assessment skipped — #{e.message}"
        nil
      end

      def risk_assessment(pr, report)
        response = @llm_client.complete_with_schema(risk_prompt(pr, report), Schemas::RISK_ASSESSMENT_SCHEMA)
        content = response&.content
        content = JSON.parse(content) if content.is_a?(String)
        content if content.is_a?(Hash)
      end

      def risk_prompt(pr, _report)
        <<~PROMPT
          A pull request has already passed all of Thingie's automated approval rules,
          so do NOT restate or list those rules. Instead, look at the actual code change
          below and give an honest assessment of the real-world risk of merging it,
          focused on: regressions in existing behavior, downtime or availability impact,
          and whether it removes or weakens any security controls.

          Pull request: #{pr.title}

          Code changes (diff):
          #{pr_diff[0, 12_000]}

          Review summary for context:
          #{@review_summary[0, 3000]}

          Auto-approval is appropriate for Low or Medium risk. Return risk_level of "Low"
          or "Medium" and a one-to-three sentence reason that justifies the approval,
          grounded in the code change (call out any regression, downtime, or security
          concern you do see, even if you still rate it Medium).
        PROMPT
      end

      # Unified diff of the PR's changed files, for the risk assessment. Best
      # effort: an API failure just yields an empty diff (risk section still runs
      # on the summary, or is omitted if that also fails).
      def pr_diff
        @client.pull_request_files(slug, @pr_number).filter_map do |file|
          next unless file.patch

          "--- #{file.filename}\n#{file.patch}"
        end.join("\n\n")
      rescue Octokit::Error, Pacing::Throttled
        ''
      end

      def details_section(report)
        rows = ["- Thingie version: #{Thingie::VERSION}"]
        rows << "- Review model: #{report.model}" unless report.model.to_s.strip.empty?
        "<details><summary>Thingie details</summary>\n\n#{rows.join("\n")}\n\n</details>"
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
        rescue Octokit::Error, Pacing::Throttled => e
          last_error = e
        end
        warn "Could not #{action} — #{last_error&.message}"
      end

      def approved_for?(sha)
        thingie_approvals.any? { |review| review.commit_id == sha }
      end

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
      rescue Octokit::Error, Pacing::Throttled
        true
      end

      # Each human reviewer's most recent approval-affecting review state, so a
      # later approval or dismissal supersedes an earlier CHANGES_REQUESTED.
      # Thingie's own reviews (APPROVAL_MARKER) are ignored; COMMENTED/PENDING
      # reviews don't change a reviewer's state and are skipped.
      def latest_human_review_states
        @client.pull_request_reviews(slug, @pr_number).each_with_object({}) do |review, states|
          next if review.body.to_s.include?(APPROVAL_MARKER)
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
      def sync_status_comment(pr, decision, report)
        existing = status_comment
        if decision.action == :approve && dry_run?
          upsert_status_comment(existing, dry_run_approval_body(pr, report))
        elsif decision.action == :approve
          remove_status_comment(existing) if existing
        else
          upsert_status_comment(existing, status_body(decision))
        end
      rescue Octokit::Error, Pacing::Throttled => e
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
