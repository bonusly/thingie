# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::Commenter do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:commenter) do
    described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1)
  end

  let(:client) { instance_double(Octokit::Client) }

  let(:pr) { double('pr', head: double('head', sha: 'commit-sha')) } # rubocop:disable RSpec/VerifiedDoubles

  # app.rb hunk covers new-side lines 10-13 (line 11 is an addition).
  # changed.rb hunk covers new-side lines 5-6 (line 6 is an addition).
  let(:pr_files) do
    [
      double('file', filename: 'app.rb', # rubocop:disable RSpec/VerifiedDoubles
                     patch: "@@ -10,3 +10,4 @@\n ctx10\n+added11\n ctx12\n ctx13"),
      double('file', filename: 'changed.rb', # rubocop:disable RSpec/VerifiedDoubles
                     patch: "@@ -5,2 +5,2 @@\n ctx5\n-old\n+added6")
    ]
  end

  before do
    allow(Octokit::Client).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_request: pr,
      pull_request_files: pr_files,
      issue_comments: []
    )
    allow(client).to receive(:create_pull_request_comment)
    allow(client).to receive(:add_comment)
    # GraphQL review-thread fetch returns no threads by default.
    allow(client).to receive(:post).and_return({})
  end

  def build_issue(file, start_line)
    raw = Thingie::RawIssue.new(title: 'T', severity: 1, confidence: 1, details: 'd', tags: ['bug'])
    range = Thingie::AffectedRange.new(start_line: start_line, end_line: start_line)
    Thingie::Issue.new(id: 1, file: file, raw_issue: raw, affected_lines: [range])
  end

  def report_for(issues)
    target = Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 1, commit_sha: nil,
                                       branch: nil, base_ref: nil, head_ref: nil, merge_base: false)
    Thingie::Report.new(target: target, model: 'm', issues: issues)
  end

  it 'posts an inline comment when the line is part of the diff' do
    commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

    expect(client).to have_received(:create_pull_request_comment)
      .with('o/r', 1, anything, 'commit-sha', 'app.rb', 11, { side: 'RIGHT' })
  end

  it 'includes the severity label in the inline comment body' do
    commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

    expect(client).to have_received(:create_pull_request_comment)
      .with('o/r', 1, a_string_including('[Critical]'), 'commit-sha', 'app.rb', 11, { side: 'RIGHT' })
  end

  describe 'pacing' do
    def github_error(klass, message)
      klass.new(method: :post, url: 'https://api.github.com', status: 422,
                body: JSON.generate({ message: message }),
                response_headers: { 'content-type' => 'application/json' })
    end

    # Stubbing the subject's own sleep is the point: these specs assert the
    # retry path without spending the backoff.
    before { allow(commenter).to receive(:sleep) } # rubocop:disable RSpec/SubjectStub

    it 'retries an inline comment GitHub says arrived too quickly' do
      calls = 0
      allow(client).to receive(:create_pull_request_comment) do
        calls += 1
        raise github_error(Octokit::UnprocessableEntity, 'was submitted too quickly') if calls < 2

        nil
      end

      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(calls).to eq(2)
    end

    it 'retries the summary comment through a secondary rate limit' do
      calls = 0
      allow(client).to receive(:add_comment) do
        calls += 1
        raise github_error(Octokit::Forbidden, 'You have exceeded a secondary rate limit') if calls < 3

        nil
      end

      commenter.post_review(summary: 'All good', report: report_for([]))

      expect(calls).to eq(3)
    end

    # An off-diff line is a permanent "no", and the existing off-diff handling
    # must keep seeing it rather than the caller waiting out four backoffs.
    it 'does not retry a comment rejected for being outside the diff' do
      calls = 0
      allow(client).to receive(:create_pull_request_comment) do
        calls += 1
        raise github_error(Octokit::UnprocessableEntity, 'line must be part of the diff')
      end

      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(calls).to eq(1)
    end

    it 'reports an off-diff rejection in the off-diff comment' do
      allow(client).to receive(:create_pull_request_comment)
        .and_raise(github_error(Octokit::UnprocessableEntity, 'line must be part of the diff'))

      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('outside this diff'))
    end
  end

  it 'posts the summary comment only when there are no issues', :aggregate_failures do
    commenter.post_review(summary: 'All good', report: report_for([]))

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('All good'))
    expect(client).not_to have_received(:create_pull_request_comment)
  end

  it 'does not post any PR-level comment when an in-diff issue is found' do
    commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

    expect(client).not_to have_received(:add_comment)
  end

  it 'collapses issues outside the diff into a details comment, not the summary', :aggregate_failures do
    commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 999)]))

    expect(client).not_to have_received(:create_pull_request_comment)
    expect(client).to have_received(:add_comment)
      .with('o/r', 1, a_string_including('<details>', 'outside this diff', 'app.rb:999'))
  end

  context 'when resolving stale review threads' do
    let(:stale_thread) do
      {
        'id' => 'THREAD1', 'isResolved' => false, 'isOutdated' => false,
        'line' => 42, 'path' => 'gone.rb',
        'comments' => { 'nodes' => [{ 'author' => { 'login' => 'bot' },
                                      'body' => "x #{described_class::REVIEW_COMMENT_MARKER}" }] }
      }
    end

    before do
      allow(client).to receive(:post) do |_path, body|
        if JSON.parse(body)['query'].include?('reviewThreads')
          { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => [stale_thread] } } } } }
        else
          {}
        end
      end
    end

    it 'resolves a Thingie thread whose issue is no longer reported, without needing the bot login' do
      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(client).to have_received(:post)
        .with('/graphql', a_string_including('resolveReviewThread'))
    end

    context 'with a dedicated resolve token' do
      subject(:commenter) do
        described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, resolve_token: 'pat')
      end

      let(:resolve_client) { instance_double(Octokit::Client) }

      before do
        # The resolve token must build its own client; route that one to a
        # distinct double and feed the stale thread through it.
        allow(Octokit::Client).to receive(:new).with(hash_including(access_token: 'pat')).and_return(resolve_client)
        allow(resolve_client).to receive(:post) do |_path, body|
          if JSON.parse(body)['query'].include?('reviewThreads')
            { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => [stale_thread] } } } } }
          else
            {}
          end
        end
      end

      it 'uses the resolve-token client for GraphQL, not the main client', :aggregate_failures do
        commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

        expect(Octokit::Client).to have_received(:new).with(hash_including(access_token: 'pat'))
        expect(resolve_client).to have_received(:post).with('/graphql', a_string_including('resolveReviewThread'))
        expect(client).not_to have_received(:post)
      end
    end
  end
end
