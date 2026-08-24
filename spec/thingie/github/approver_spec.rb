# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::Approver do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:approver) do
    described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, config: config)
  end

  let(:config) { { 'enabled' => true } }
  let(:client) { instance_double(Octokit::Client) }

  # rubocop:disable RSpec/VerifiedDoubles
  let(:pr) do
    double('pr', draft: false, additions: 10, deletions: 20, title: 'Example PR',
                 head: double('head', sha: 'sha1'), user: double('user', login: 'author'),
                 labels: [])
  end
  # rubocop:enable RSpec/VerifiedDoubles

  # Default: no threads. Per-example overrides stub :post with thread nodes.
  before do
    allow(Octokit::Client).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_request: pr,
      pull_request_commits: [],
      pull_request_files: [],
      pull_request_reviews: [],
      issue_comments: [],
      user: double('me', login: 'thingie-bot'), # rubocop:disable RSpec/VerifiedDoubles
      post: threads_response([])
    )
    allow(client).to receive(:create_pull_request_review)
    allow(client).to receive(:dismiss_pull_request_review)
    allow(client).to receive(:add_comment)
    allow(client).to receive(:update_comment)
    allow(client).to receive(:delete_comment)
  end

  def threads_response(nodes)
    { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => nodes } } } } }
  end

  def stub_threads(nodes)
    allow(client).to receive(:post).and_return(threads_response(nodes))
  end

  def thingie_thread(severity: 'Critical', resolved: false, resolved_by: nil)
    {
      'id' => 'T1', 'isResolved' => resolved, 'isOutdated' => false, 'line' => 1, 'path' => 'a.rb',
      'resolvedBy' => resolved_by && { 'login' => resolved_by },
      'comments' => { 'nodes' => [{ 'author' => { 'login' => 'thingie-bot' },
                                    'body' => "#{Thingie::GitHub::Commenter::REVIEW_COMMENT_MARKER} [#{severity}] x" }] }
    }
  end

  def report_for(issues)
    target = Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 1, commit_sha: nil,
                                       branch: nil, base_ref: nil, head_ref: nil, merge_base: false)
    Thingie::Report.new(target: target, model: 'm', issues: issues)
  end

  def build_issue(severity)
    raw = Thingie::RawIssue.new(title: 'T', severity: severity, confidence: 1, details: 'd', tags: [])
    Thingie::Issue.new(id: 1, file: 'a.rb', raw_issue: raw, affected_lines: [])
  end

  def stub_commit_authors(*logins)
    commits = logins.map { |login| double('c', author: double('a', login: login), committer: nil) } # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:pull_request_commits).and_return(commits)
  end

  def stub_existing_approval(commit_id:, id: 99)
    review = double('rev', id: id, state: 'APPROVED', commit_id: commit_id, # rubocop:disable RSpec/VerifiedDoubles
                           body: described_class::APPROVAL_MARKER)
    allow(client).to receive(:pull_request_reviews).and_return([review])
  end

  def human_review(login:, state:, body: '', id: 1)
    double('review', id: id, state: state, body: body, user: double('u', login: login)) # rubocop:disable RSpec/VerifiedDoubles
  end

  def stub_reviews(*reviews)
    allow(client).to receive(:pull_request_reviews).and_return(reviews)
  end

  it 'approves a clean PR with the approval marker' do
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(event: 'APPROVE', body: a_string_including(described_class::APPROVAL_MARKER)))
  end

  it 'enriches the approval body with the passed-rules checklist and Thingie details' do
    approver.run(report_for([]))

    expected_body = a_string_including('Checks passed')
                    .and(a_string_including("Thingie version: #{Thingie::VERSION}"))
                    .and(a_string_including('Review model: m'))
    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(body: expected_body))
  end

  it 'omits the risk assessment when no LLM client is configured' do
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review).with(
      'o/r', 1, hash_including(body: satisfy('excludes risk assessment') { |b| !b.include?('Risk assessment') })
    )
  end

  it 'labels the severity threshold in the passed-rules checklist' do
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(body: a_string_including('No findings at or above Medium (3)')))
  end

  it 'lists configured external checks in the approval body' do
    config['external_checks'] = ['Security review pass', 'Full test suite']
    approver.run(report_for([]))

    expected = a_string_including('Other checks that must pass before merge')
               .and(a_string_including('Security review pass'))
               .and(a_string_including('Full test suite'))
    expect(client).to have_received(:create_pull_request_review).with('o/r', 1, hash_including(body: expected))
  end

  it 'omits the external checks section when none are configured' do
    approver.run(report_for([]))

    no_external = satisfy('excludes external checks') { |b| !b.include?('Other checks that must pass') }
    expect(client).to have_received(:create_pull_request_review).with('o/r', 1, hash_including(body: no_external))
  end

  context 'with an LLM client for the risk assessment' do
    subject(:approver) do
      described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, config: config,
                          llm_client: llm_client, review_summary: 'summary text')
    end

    let(:llm_client) { instance_double(Thingie::LlmClient) }

    it 'adds the LLM risk level and summary to the approval body' do
      response = double('resp', content: { 'risk_level' => 'Low', 'summary' => 'Looks safe.' }) # rubocop:disable RSpec/VerifiedDoubles
      allow(llm_client).to receive(:complete_with_schema).and_return(response)
      approver.run(report_for([]))

      expect(client).to have_received(:create_pull_request_review).with(
        'o/r', 1,
        hash_including(body: a_string_including('Risk assessment: Low').and(a_string_including('Looks safe.')))
      )
    end

    it 'still approves without a risk section when the LLM call fails' do
      allow(llm_client).to receive(:complete_with_schema).and_raise(StandardError)
      approver.run(report_for([]))

      expect(client).to have_received(:create_pull_request_review).with(
        'o/r', 1, hash_including(body: satisfy('no risk section') { |b| !b.include?('Risk assessment') })
      )
    end
  end

  it 'blocks when the PR exceeds the change limit' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks approval when GitHub does not report the change size' do
    allow(pr).to receive_messages(additions: nil, deletions: nil)
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks when the PR changes the Thingie config' do
    allow(client).to receive(:pull_request_files)
      .and_return([double('file', filename: '.thingie/config.toml')]) # rubocop:disable RSpec/VerifiedDoubles
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks approval when the report contains an obfuscation finding' do
    raw = Thingie::RawIssue.new(title: 'Obfuscated code detected', severity: 1, confidence: 1,
                                details: 'd', tags: %w[security obfuscation])
    issue = Thingie::Issue.new(id: 1, file: 'payload.rb', raw_issue: raw, affected_lines: [])
    approver.run(report_for([issue]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'names the obfuscated files in the status comment' do
    raw = Thingie::RawIssue.new(title: 'Obfuscated code detected', severity: 1, confidence: 1,
                                details: 'd', tags: %w[security obfuscation])
    issue = Thingie::Issue.new(id: 1, file: 'payload.rb', raw_issue: raw, affected_lines: [])
    approver.run(report_for([issue]))

    expect(client).to have_received(:add_comment)
      .with('o/r', 1, a_string_including('obfuscated code detected in payload.rb'))
  end

  it 'blocks on obfuscation even at a permissive severity threshold' do
    config['max_severity'] = 4
    raw = Thingie::RawIssue.new(title: 'Obfuscated code detected', severity: 1, confidence: 1,
                                details: 'd', tags: %w[security obfuscation])
    issue = Thingie::Issue.new(id: 1, file: 'payload.rb', raw_issue: raw, affected_lines: [])
    approver.run(report_for([issue]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks when a changed file matches a protected glob' do
    config['protected_paths'] = ['app/billing/**']
    allow(client).to receive(:pull_request_files)
      .and_return([double('file', filename: 'app/billing/charge.rb')]) # rubocop:disable RSpec/VerifiedDoubles
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves when changed files do not match any protected glob' do
    config['protected_paths'] = ['app/billing/**']
    allow(client).to receive(:pull_request_files)
      .and_return([double('file', filename: 'app/models/user.rb')]) # rubocop:disable RSpec/VerifiedDoubles
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'blocks when the current run has a qualifying finding' do
    approver.run(report_for([build_issue(2)]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves when the current run only has a finding below the threshold' do
    approver.run(report_for([build_issue(4)]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'blocks on an unresolved qualifying Thingie thread' do
    stub_threads([thingie_thread(resolved: false)])
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks when a qualifying thread was resolved by the PR author' do
    stub_threads([thingie_thread(resolved: true, resolved_by: 'author')])
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks when a qualifying thread was resolved by a contributor' do
    stub_commit_authors('dev')
    stub_threads([thingie_thread(resolved: true, resolved_by: 'dev')])
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves when a qualifying thread was resolved by an independent reviewer' do
    stub_threads([thingie_thread(resolved: true, resolved_by: 'reviewer')])
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'blocks when a human reviewer requested changes' do
    stub_reviews(human_review(login: 'dev', state: 'CHANGES_REQUESTED'))
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves once the reviewer dismissed the changes request' do
    stub_reviews(human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'DISMISSED'))
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'approves once the reviewer re-approved after requesting changes' do
    stub_reviews(human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'APPROVED'))
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'stays blocked when the reviewer only commented after requesting changes' do
    stub_reviews(human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'COMMENTED'))
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it "ignores Thingie's own reviews when checking for human requested changes" do
    stub_reviews(
      human_review(login: 'thingie[bot]', state: 'APPROVED', body: described_class::APPROVAL_MARKER),
      human_review(login: 'dev', state: 'CHANGES_REQUESTED')
    )
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks (fails safe) when the review state cannot be determined' do
    allow(client).to receive(:pull_request_reviews).and_raise(Octokit::InternalServerError)
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips a PR carrying the skip label' do
    allow(pr).to receive(:labels).and_return([double('l', name: 'thingie-skip-approve')]) # rubocop:disable RSpec/VerifiedDoubles
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips a draft PR' do
    allow(pr).to receive(:draft).and_return(true)
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips when the approving identity is the PR author' do
    allow(client).to receive(:user).and_return(double('me', login: 'author')) # rubocop:disable RSpec/VerifiedDoubles
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  context 'with approval_team gating' do
    let(:membership_path) { '/orgs/bonusly/teams/pr-auto-approval/memberships/author' }

    before { config['approval_team'] = 'bonusly/pr-auto-approval' }

    it 'approves when the PR author is an active team member' do
      allow(client).to receive(:get).with(membership_path).and_return({ state: 'active' })
      approver.run(report_for([]))

      expect(client).to have_received(:create_pull_request_review)
    end

    it 'does not approve when the PR author is not a team member' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::NotFound)
      approver.run(report_for([]))

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'does not approve when team membership cannot be determined' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::Forbidden)
      approver.run(report_for([]))

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'does not approve when the membership is pending rather than active' do
      allow(client).to receive(:get).with(membership_path).and_return({ state: 'pending' })
      approver.run(report_for([]))

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'leaves an existing approval in place for a non-member (skip, not block)' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::NotFound)
      stub_existing_approval(commit_id: 'sha1')
      approver.run(report_for([]))

      expect(client).not_to have_received(:dismiss_pull_request_review)
    end
  end

  it 'ignores team gating when approval_team is unset' do
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'posts the successful approval result without approving in dry-run mode', :aggregate_failures do
    config['dry_run'] = true
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
    expected_body = a_string_including(described_class::STATUS_MARKER)
                    .and(a_string_including('Dry run — no approval action was taken'))
                    .and(a_string_including('would automatically approve this PR'))
                    .and(a_string_including('Checks passed'))
                    .and(a_string_including("Thingie version: #{Thingie::VERSION}"))
    expect(client).to have_received(:add_comment).with('o/r', 1, expected_body)
  end

  it 'posts a status comment explaining why the PR was not approved' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run(report_for([]))

    expect(client).to have_received(:add_comment)
      .with('o/r', 1, a_string_including('max 500'))
  end

  it 'updates an existing status comment instead of posting a duplicate', :aggregate_failures do
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run(report_for([]))

    expect(client).to have_received(:update_comment).with('o/r', 7, anything)
    expect(client).not_to have_received(:add_comment)
  end

  it 'removes a stale status comment when the PR now qualifies for approval' do
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    approver.run(report_for([]))

    expect(client).to have_received(:delete_comment).with('o/r', 7)
  end

  it 'updates a stale status comment with the successful dry-run result', :aggregate_failures do
    config['dry_run'] = true
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    approver.run(report_for([]))

    expect(client).to have_received(:update_comment)
      .with('o/r', 7, a_string_including('would automatically approve this PR'))
    expect(client).not_to have_received(:delete_comment)
  end

  it 'still posts a blocked status comment in dry-run mode' do
    config['dry_run'] = true
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run(report_for([]))

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('Dry run'))
  end

  it 'includes the Thingie version in the status comment' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run(report_for([]))

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including("Thingie v#{Thingie::VERSION}"))
  end

  it 'includes the Thingie version in the approval review body' do
    approver.run(report_for([]))

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(body: a_string_including("Thingie version: #{Thingie::VERSION}")))
  end

  it 'does not duplicate an approval already present for the head SHA' do
    stub_existing_approval(commit_id: 'sha1')
    approver.run(report_for([]))

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'dismisses a stale Thingie approval when a rule now fails' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    stub_existing_approval(commit_id: 'old', id: 99)
    approver.run(report_for([]))

    expect(client).to have_received(:dismiss_pull_request_review).with('o/r', 1, 99, anything)
  end

  it 'dismisses an approval left over from an earlier commit before re-approving the head', :aggregate_failures do
    stub_existing_approval(commit_id: 'old', id: 42)
    approver.run(report_for([]))

    expect(client).to have_received(:dismiss_pull_request_review).with('o/r', 1, 42, anything)
    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(event: 'APPROVE'))
  end

  context 'when the main token cannot approve and a PAT fallback is configured' do
    subject(:approver) do
      described_class.new(token: 'gh', owner: 'o', repo: 'r', pr_number: 1, config: config, resolve_token: 'pat')
    end

    let(:pat_client) { instance_double(Octokit::Client) }

    before do
      allow(Octokit::Client).to receive(:new).with(hash_including(access_token: 'pat')).and_return(pat_client)
      allow(client).to receive(:create_pull_request_review).and_raise(Octokit::Forbidden)
      allow(pat_client).to receive(:create_pull_request_review)
    end

    it 'falls back to the PAT after the main token approval fails', :aggregate_failures do
      approver.run(report_for([]))

      expect(client).to have_received(:create_pull_request_review)
      expect(pat_client).to have_received(:create_pull_request_review).with('o/r', 1, anything)
    end
  end

  context 'when run returns the decision' do
    it 'returns an approve Decision for a clean PR' do
      decision = approver.run(report_for([]))
      expect(decision.action).to eq(:approve)
      expect(decision.reasons).to eq([])
    end

    it 'returns a block Decision with reasons when a rule fails' do
      allow(pr).to receive_messages(additions: 600, deletions: 0) # exceeds max_changes (500)

      decision = approver.run(report_for([]))
      expect(decision.action).to eq(:block)
      expect(decision.reasons).to include(include('600 changes'))
    end

    it 'returns nil when the client raises' do
      allow(client).to receive(:pull_request).and_raise(StandardError, 'boom')

      expect(approver.run(report_for([]))).to be_nil
    end
  end
end
