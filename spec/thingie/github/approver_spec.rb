# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::Approver do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:approver) do
    described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, config: config)
  end

  let(:config) { { 'enabled' => true } }
  let(:client) { instance_double(Octokit::Client) }

  # rubocop:disable-next RSpec/VerifiedDoubles
  let(:pr) do
    double('pr', draft: false, additions: 10, deletions: 20, title: 'Example PR',
                 head: double('head', sha: 'sha1'), user: double('user', login: 'author'),
                 labels: [])
  end

  before do
    allow(Octokit::Client).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_request: pr,
      pull_request_files: [],
      pull_request_reviews: [copilot_review],
      issue_comments: [],
      contents: "puts 'ok'\n",
      user: double('me', login: 'thingie-bot') # rubocop:disable RSpec/VerifiedDoubles
    )
    allow(client).to receive(:create_pull_request_review)
    allow(client).to receive(:dismiss_pull_request_review)
    allow(client).to receive(:add_comment)
    allow(client).to receive(:update_comment)
    allow(client).to receive(:delete_comment)
  end

  def copilot_review(state: 'APPROVED', commit_id: 'sha1', login: described_class::COPILOT_LOGIN, type: 'Bot')
    user = double('u', login: login, type: type) # rubocop:disable RSpec/VerifiedDoubles
    double('copilot review', id: 5, state: state, commit_id: commit_id, body: '', user: user) # rubocop:disable RSpec/VerifiedDoubles
  end

  def changed_file(filename, status: 'modified')
    double('file', filename: filename, status: status) # rubocop:disable RSpec/VerifiedDoubles
  end

  def thingie_approval(commit_id:, id: 99)
    user = double('u', login: 'thingie-bot', type: 'User') # rubocop:disable RSpec/VerifiedDoubles
    double('rev', id: id, state: 'APPROVED', commit_id: commit_id, # rubocop:disable RSpec/VerifiedDoubles
                  body: described_class::APPROVAL_MARKER, user: user)
  end

  def stub_existing_approval(commit_id:, id: 99)
    stub_reviews(copilot_review, thingie_approval(commit_id: commit_id, id: id))
  end

  def human_review(login:, state:, body: '', id: 1)
    double('review', id: id, state: state, body: body, user: double('u', login: login, type: 'User')) # rubocop:disable RSpec/VerifiedDoubles
  end

  def stub_reviews(*reviews)
    allow(client).to receive(:pull_request_reviews).and_return(reviews)
  end

  it 'approves a clean PR with the approval marker' do
    approver.run

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(event: 'APPROVE', body: a_string_including(described_class::APPROVAL_MARKER)))
  end

  it 'enriches the approval body with the passed-rules checklist and Thingie details' do
    approver.run

    expected_body = a_string_including('Checks passed')
                    .and(a_string_including('Copilot approved the current commit'))
                    .and(a_string_including("Thingie v#{Thingie::VERSION}"))
    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(body: expected_body))
  end

  it 'lists configured external checks in the approval body' do
    config['external_checks'] = ['Security review pass', 'Full test suite']
    approver.run

    expected = a_string_including('**Checks not evaluated**')
               .and(a_string_including('Security review pass'))
               .and(a_string_including('Full test suite'))
    expect(client).to have_received(:create_pull_request_review).with('o/r', 1, hash_including(body: expected))
  end

  it 'omits the external checks section when none are configured' do
    approver.run

    no_external = satisfy('excludes external checks') { |b| !b.include?('Other checks that must pass') }
    expect(client).to have_received(:create_pull_request_review).with('o/r', 1, hash_including(body: no_external))
  end

  it 'blocks when the PR exceeds the change limit' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks approval when GitHub does not report the change size' do
    allow(pr).to receive_messages(additions: nil, deletions: nil)
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks when the PR changes the Thingie config' do
    allow(client).to receive(:pull_request_files)
      .and_return([changed_file('.thingie/config.toml')])
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves the exact commit it evaluated' do
    approver.run

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(commit_id: 'sha1'))
  end

  context 'with Copilot reviews' do
    def block_reasons
      approver.run.reasons
    end

    it 'blocks when Copilot has not reviewed the PR', :aggregate_failures do
      stub_reviews

      expect(block_reasons).to eq(['Copilot has not reviewed this PR'])
      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'blocks when Copilot last reviewed an earlier commit' do
      stub_reviews(copilot_review(commit_id: 'old'))

      expect(block_reasons).to eq(['Copilot has not reviewed the latest commit yet'])
    end

    it 'blocks when Copilot recommended changes on the current commit' do
      stub_reviews(copilot_review(state: 'COMMENTED'))

      expect(block_reasons).to eq(['Copilot did not recommend approval (its latest review is commented)'])
    end

    it "blocks when Copilot's approval was dismissed" do
      stub_reviews(copilot_review(state: 'DISMISSED'))

      expect(block_reasons).to eq(['Copilot did not recommend approval (its latest review is dismissed)'])
    end

    it "goes by Copilot's latest review, not an earlier approval" do
      stub_reviews(copilot_review, copilot_review(state: 'COMMENTED'))

      expect(block_reasons).to eq(['Copilot did not recommend approval (its latest review is commented)'])
    end

    it 'approves once Copilot approves after recommending changes' do
      stub_reviews(copilot_review(state: 'COMMENTED'), copilot_review)

      expect(approver.run.action).to eq(:approve)
    end

    it 'ignores an approval from a user account that copies the Copilot login' do
      stub_reviews(copilot_review(type: 'User'))

      expect(block_reasons).to eq(['Copilot has not reviewed this PR'])
    end

    it 'ignores approvals from other bots' do
      stub_reviews(copilot_review(login: 'other-reviewer[bot]'))

      expect(block_reasons).to eq(['Copilot has not reviewed this PR'])
    end

    it 'says why on the PR and dismisses a stale Thingie approval', :aggregate_failures do
      stub_reviews(copilot_review(commit_id: 'old'), thingie_approval(commit_id: 'old', id: 99))
      approver.run

      expect(client).to have_received(:dismiss_pull_request_review).with('o/r', 1, 99, anything)
      expect(client).to have_received(:add_comment)
        .with('o/r', 1, a_string_including('Copilot has not reviewed the latest commit yet'))
    end
  end

  context 'when scanning changed files for obfuscated code' do
    before do
      allow(client).to receive(:pull_request_files)
        .and_return([changed_file('payload.rb'), changed_file('gone.rb', status: 'removed')])
    end

    it 'reads each changed file at the head commit', :aggregate_failures do
      approver.run

      expect(client).to have_received(:contents)
        .with('o/r', path: 'payload.rb', ref: 'sha1', accept: 'application/vnd.github.raw')
      expect(client).not_to have_received(:contents).with('o/r', hash_including(path: 'gone.rb'))
    end

    it 'blocks and names the file when one holds obfuscated code', :aggregate_failures do
      allow(client).to receive(:contents).and_return("payload = '#{ObfuscationSamples::HEX_BLOB}'\n")

      expect(approver.run.reasons).to eq(['obfuscated code detected in payload.rb'])
      expect(client).to have_received(:add_comment)
        .with('o/r', 1, a_string_including('obfuscated code detected in payload.rb'))
    end

    it 'blocks when a changed file cannot be read' do
      allow(client).to receive(:contents).and_raise(Octokit::NotFound)

      expect(approver.run.reasons)
        .to eq(['1 file(s) could not be read to scan for obfuscated code (payload.rb)'])
    end

    it 'does not scan the bytes of a binary file' do
      allow(client).to receive(:contents).and_return("\x89PNG\r\n\x1A\n\0\0#{ObfuscationSamples::HEX_BLOB}")

      expect(approver.run.action).to eq(:approve)
    end
  end

  it 'blocks when a changed file matches a protected glob' do
    config['protected_paths'] = ['app/billing/**']
    allow(client).to receive(:pull_request_files)
      .and_return([changed_file('app/billing/charge.rb')])
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves when changed files do not match any protected glob' do
    config['protected_paths'] = ['app/billing/**']
    allow(client).to receive(:pull_request_files)
      .and_return([changed_file('app/models/user.rb')])
    approver.run

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'blocks when a human reviewer requested changes' do
    stub_reviews(copilot_review, human_review(login: 'dev', state: 'CHANGES_REQUESTED'))
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'approves once the reviewer dismissed the changes request' do
    stub_reviews(copilot_review, human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'DISMISSED'))
    approver.run

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'approves once the reviewer re-approved after requesting changes' do
    stub_reviews(copilot_review, human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'APPROVED'))
    approver.run

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'stays blocked when the reviewer only commented after requesting changes' do
    stub_reviews(copilot_review, human_review(login: 'dev', state: 'CHANGES_REQUESTED'),
                 human_review(login: 'dev', state: 'COMMENTED'))
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it "ignores Thingie's own reviews when checking for human requested changes" do
    stub_reviews(
      copilot_review,
      human_review(login: 'thingie[bot]', state: 'APPROVED', body: described_class::APPROVAL_MARKER),
      human_review(login: 'dev', state: 'CHANGES_REQUESTED')
    )
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'blocks (fails safe) when the review state cannot be determined' do
    allow(client).to receive(:pull_request_reviews).and_raise(Octokit::InternalServerError)
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips a PR carrying the skip label' do
    allow(pr).to receive(:labels).and_return([double('l', name: 'thingie-skip-approve')]) # rubocop:disable RSpec/VerifiedDoubles
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips a draft PR' do
    allow(pr).to receive(:draft).and_return(true)
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'skips when the approving identity is the PR author' do
    allow(client).to receive(:user).and_return(double('me', login: 'author')) # rubocop:disable RSpec/VerifiedDoubles
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  context 'with approval_team gating' do
    let(:membership_path) { '/orgs/bonusly/teams/pr-auto-approval/memberships/author' }

    before { config['approval_team'] = 'bonusly/pr-auto-approval' }

    it 'approves when the PR author is an active team member' do
      allow(client).to receive(:get).with(membership_path).and_return({ state: 'active' })
      approver.run

      expect(client).to have_received(:create_pull_request_review)
    end

    it 'does not approve when the PR author is not a team member' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::NotFound)
      approver.run

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'does not approve when team membership cannot be determined' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::Forbidden)
      approver.run

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'does not approve when the membership is pending rather than active' do
      allow(client).to receive(:get).with(membership_path).and_return({ state: 'pending' })
      approver.run

      expect(client).not_to have_received(:create_pull_request_review)
    end

    it 'leaves an existing approval in place for a non-member (skip, not block)' do
      allow(client).to receive(:get).with(membership_path).and_raise(Octokit::NotFound)
      stub_existing_approval(commit_id: 'sha1')
      approver.run

      expect(client).not_to have_received(:dismiss_pull_request_review)
    end

    context 'when the author is a listed bot' do
      let(:pr) do
        double('pr', draft: false, additions: 10, deletions: 20, title: 'Example PR', # rubocop:disable RSpec/VerifiedDoubles
                     head: double('head', sha: 'sha1'), user: double('user', login: 'loop-de-loops[bot]'), # rubocop:disable RSpec/VerifiedDoubles
                     labels: [])
      end

      before do
        config['approval_bots'] = ['loop-de-loops[bot]']
        allow(client).to receive(:get)
      end

      it 'approves without a team lookup', :aggregate_failures do
        approver.run

        expect(client).to have_received(:create_pull_request_review)
          .with('o/r', 1, hash_including(body: a_string_including('Author loop-de-loops[bot] is an approved bot')))
        expect(client).not_to have_received(:get)
      end

      it 'still blocks on a protected path' do
        config['protected_paths'] = ['db/**/*']
        allow(client).to receive(:pull_request_files).and_return([changed_file('db/schema.rb')])
        approver.run

        expect(client).not_to have_received(:create_pull_request_review)
      end
    end

    context 'when the author is a bot that is not listed' do
      let(:pr) do
        double('pr', draft: false, additions: 10, deletions: 20, title: 'Example PR', # rubocop:disable RSpec/VerifiedDoubles
                     head: double('head', sha: 'sha1'), user: double('user', login: 'other-bot[bot]'), # rubocop:disable RSpec/VerifiedDoubles
                     labels: [])
      end

      it 'does not approve' do
        config['approval_bots'] = ['loop-de-loops[bot]']
        allow(client).to receive(:get)
          .with('/orgs/bonusly/teams/pr-auto-approval/memberships/other-bot[bot]').and_raise(Octokit::NotFound)
        approver.run

        expect(client).not_to have_received(:create_pull_request_review)
      end
    end
  end

  it 'ignores team gating when approval_team is unset' do
    approver.run

    expect(client).to have_received(:create_pull_request_review)
  end

  it 'posts the successful approval result without approving in dry-run mode', :aggregate_failures do
    config['dry_run'] = true
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
    expected_body = a_string_including(described_class::STATUS_MARKER)
                    .and(a_string_including('Dry run — no approval action was taken'))
                    .and(a_string_including('would automatically approve this PR'))
                    .and(a_string_including('Checks passed'))
                    .and(a_string_including("Thingie v#{Thingie::VERSION}"))
    expect(client).to have_received(:add_comment).with('o/r', 1, expected_body)
  end

  it 'posts a status comment explaining why the PR was not approved' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run

    expect(client).to have_received(:add_comment)
      .with('o/r', 1, a_string_including('max 500'))
  end

  it 'updates an existing status comment instead of posting a duplicate', :aggregate_failures do
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run

    expect(client).to have_received(:update_comment).with('o/r', 7, anything)
    expect(client).not_to have_received(:add_comment)
  end

  it 'removes a stale status comment when the PR now qualifies for approval' do
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    approver.run

    expect(client).to have_received(:delete_comment).with('o/r', 7)
  end

  it 'updates a stale status comment with the successful dry-run result', :aggregate_failures do
    config['dry_run'] = true
    existing = double('comment', id: 7, body: described_class::STATUS_MARKER) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:issue_comments).and_return([existing])
    approver.run

    expect(client).to have_received(:update_comment)
      .with('o/r', 7, a_string_including('would automatically approve this PR'))
    expect(client).not_to have_received(:delete_comment)
  end

  it 'still posts a blocked status comment in dry-run mode' do
    config['dry_run'] = true
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('Dry run'))
  end

  it 'includes the Thingie version in the status comment' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    approver.run

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including("_Thingie v#{Thingie::VERSION}_"))
  end

  it 'includes the Thingie version in the approval review body' do
    approver.run

    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(body: a_string_including("_Thingie v#{Thingie::VERSION}_")))
  end

  it 'does not duplicate an approval already present for the head SHA' do
    stub_existing_approval(commit_id: 'sha1')
    approver.run

    expect(client).not_to have_received(:create_pull_request_review)
  end

  it 'dismisses a stale Thingie approval when a rule now fails' do
    allow(pr).to receive_messages(additions: 600, deletions: 0)
    stub_existing_approval(commit_id: 'old', id: 99)
    approver.run

    expect(client).to have_received(:dismiss_pull_request_review).with('o/r', 1, 99, anything)
  end

  it 'dismisses an approval left over from an earlier commit before re-approving the head', :aggregate_failures do
    stub_existing_approval(commit_id: 'old', id: 42)
    approver.run

    expect(client).to have_received(:dismiss_pull_request_review).with('o/r', 1, 42, anything)
    expect(client).to have_received(:create_pull_request_review)
      .with('o/r', 1, hash_including(event: 'APPROVE'))
  end

  context 'with main_branch_run_repos' do
    let(:run_url) { 'https://github.com/bonusly/loop-de-loop/actions/runs/42' }
    let(:pr_body) { 'No runs linked here.' }
    let(:pr) do
      double('pr', draft: false, additions: 10, deletions: 20, title: 'Example PR', # rubocop:disable RSpec/VerifiedDoubles
                   head: double('head', sha: 'sha1'), user: double('user', login: 'author'), # rubocop:disable RSpec/VerifiedDoubles
                   labels: [], body: pr_body)
    end

    def comment(login, body)
      double('comment', user: double('u', login: login), body: body) # rubocop:disable RSpec/VerifiedDoubles
    end

    before do
      config['main_branch_run_repos'] = ['bonusly/loop-de-loop']
      allow(client).to receive_messages(
        issue_comments: [comment('author', "**Fixit** opened this ([run](#{run_url}))")],
        workflow_run: double('run', head_sha: 'abc', head_branch: 'test-branch'), # rubocop:disable RSpec/VerifiedDoubles
        repository: double('repo', default_branch: 'main') # rubocop:disable RSpec/VerifiedDoubles
      )
    end

    def stub_compare(status)
      allow(client).to receive(:compare).with('bonusly/loop-de-loop', 'main', 'abc')
                                        .and_return(double('comparison', status: status)) # rubocop:disable RSpec/VerifiedDoubles
    end

    it 'blocks when a run linked from the author ran a commit off the default branch', :aggregate_failures do
      stub_compare('diverged')
      decision = approver.run

      expect(client).not_to have_received(:create_pull_request_review)
      expect(decision.reasons).to include('bonusly/loop-de-loop run 42 ran from `test-branch`, not main')
    end

    context 'when the run is linked from the description' do
      let(:pr_body) { "Opened by [this run](#{run_url})." }

      it 'blocks' do
        allow(client).to receive(:issue_comments).and_return([])
        stub_compare('ahead')
        approver.run

        expect(client).not_to have_received(:create_pull_request_review)
      end
    end

    it 'ignores runs linked by someone other than the author' do
      allow(client).to receive(:issue_comments).and_return([comment('reviewer', "Repro in #{run_url}")])
      approver.run

      expect(client).not_to have_received(:workflow_run)
    end

    it 'approves and lists the check as passed when the run is on the default branch' do
      stub_compare('behind')
      approver.run

      expect(client).to have_received(:create_pull_request_review).with(
        'o/r', 1, hash_including(body: a_string_including('No linked workflow run came from off the default branch'))
      )
    end

    it 'approves but says the run was not checked when it cannot be read' do
      allow(client).to receive(:workflow_run).and_raise(Octokit::NotFound)
      approver.run

      not_claimed = satisfy('omits the passed check') { |body| !body.include?('No linked workflow run') }
      expected = a_string_including('Linked runs not checked')
                 .and(a_string_including('bonusly/loop-de-loop run 42'))
                 .and(not_claimed)
      expect(client).to have_received(:create_pull_request_review).with('o/r', 1, hash_including(body: expected))
    end

    it 'approves but says the comments were not checked when they cannot be read' do
      allow(client).to receive(:issue_comments).and_raise(Faraday::ConnectionFailed, 'reset')
      approver.run

      expect(client).to have_received(:create_pull_request_review)
        .with('o/r', 1, hash_including(body: a_string_including('comments could not be read')))
    end
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
      approver.run

      expect(client).to have_received(:create_pull_request_review)
      expect(pat_client).to have_received(:create_pull_request_review).with('o/r', 1, anything)
    end
  end

  context 'when run returns the decision' do
    it 'returns an approve Decision for a clean PR' do
      decision = approver.run
      expect(decision.action).to eq(:approve)
      expect(decision.reasons).to eq([])
    end

    it 'returns a block Decision with reasons when a rule fails' do
      allow(pr).to receive_messages(additions: 600, deletions: 0) # exceeds max_changes (500)

      decision = approver.run
      expect(decision.action).to eq(:block)
      expect(decision.reasons).to include(include('600 changes'))
    end

    it 'returns nil when the client raises' do
      allow(client).to receive(:pull_request).and_raise(StandardError, 'boom')

      expect(approver.run).to be_nil
    end
  end
end
