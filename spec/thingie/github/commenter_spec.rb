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
      issue_comments: [],
      pull_request_comments: []
    )
    allow(client).to receive(:create_pull_request_comment)
    allow(client).to receive(:add_comment)
    # GraphQL review-thread fetch returns no threads by default.
    allow(client).to receive(:post).and_return({})
  end

  def build_issue(file, start_line, evidence: nil, severity: 1)
    raw = Thingie::RawIssue.new(title: 'T', severity: severity, confidence: 1, details: 'd', tags: ['bug'],
                                evidence: evidence)
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

  it 'shows the evidence in the inline comment when the reviewer gave some' do
    issue = build_issue('app.rb', 11, evidence: 'award.rb:31 skips the check')
    commenter.post_review(summary: 'S', report: report_for([issue]))

    expect(client).to have_received(:create_pull_request_comment)
      .with('o/r', 1, a_string_including("<details><summary>Evidence</summary>\n\naward.rb:31 skips the check"),
            'commit-sha', 'app.rb', 11, { side: 'RIGHT' })
  end

  it 'posts no evidence line when there is none' do
    commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

    expect(client).to have_received(:create_pull_request_comment)
      .with('o/r', 1, satisfy { |body| !body.include?('Evidence') }, 'commit-sha', 'app.rb', 11, { side: 'RIGHT' })
  end

  it 'posts the summary comment only when there are no issues', :aggregate_failures do
    commenter.post_review(summary: 'All good', report: report_for([]))

    expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('All good'))
    expect(client).not_to have_received(:create_pull_request_comment)
  end

  context 'when the run has no findings but earlier ones are still open' do
    let(:summary) { "### Review of `abc1234`\n\n#{Thingie::ReportRenderer::NO_CHANGES}\n\nFiles reviewed (1)" }
    let(:thread_body) { "#{described_class::REVIEW_COMMENT_MARKER}\n\n**[Medium] Parser written twice**\n\nText" }
    let(:open_thread) do
      {
        'id' => 'T1', 'isResolved' => false, 'isOutdated' => false, 'line' => 11, 'path' => 'app.rb',
        'comments' => { 'nodes' => [{ 'author' => { 'login' => 'bot' }, 'body' => thread_body,
                                      'url' => 'https://github.com/o/r/pull/1#discussion_r1' }] }
      }
    end

    before do
      allow(client).to receive(:post) do |_path, body|
        if JSON.parse(body)['query'].include?('reviewThreads')
          { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => [open_thread] } } } } }
        else
          {}
        end
      end
    end

    it 'says there is nothing new and lists the open ones with their severity and a link', :aggregate_failures do
      commenter.post_review(summary: summary, report: report_for([]))

      expect(client).to have_received(:add_comment).with(
        'o/r', 1,
        a_string_including('**✅ No new changes recommended**', 'Still open from earlier reviews (1):',
                           '- **Medium:** [Parser written twice](https://github.com/o/r/pull/1#discussion_r1)',
                           'Files reviewed (1)')
      )
    end

    it 'lists a finding without its link when GitHub gave none' do
      open_thread['comments']['nodes'][0].delete('url')

      commenter.post_review(summary: summary, report: report_for([]))

      expect(client).to have_received(:add_comment)
        .with('o/r', 1, a_string_including('- **Medium:** Parser written twice (`app.rb`)'))
    end

    it 'keeps the first-review wording when the open thread is not Thingie\'s' do
      open_thread['comments']['nodes'][0]['body'] = 'a human comment'

      commenter.post_review(summary: summary, report: report_for([]))

      expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('**✅ No changes recommended**'))
    end

    context 'with more than five open' do
      let(:threads) { Array.new(7) { |n| open_thread.merge('id' => "T#{n}") } }

      before do
        allow(client).to receive(:post) do |_path, body|
          if JSON.parse(body)['query'].include?('reviewThreads')
            { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => threads } } } } }
          else
            {}
          end
        end
      end

      it 'shows five and says how many more', :aggregate_failures do
        commenter.post_review(summary: summary, report: report_for([]))

        expect(client).to have_received(:add_comment)
          .with('o/r', 1, a_string_including('Still open from earlier reviews (7):', '- and 2 more'))
      end
    end
  end

  context 'when the run has no findings and nothing is open' do
    let(:summary) { "### Review of `abc1234`\n\n#{Thingie::ReportRenderer::NO_CHANGES}\n\nFiles reviewed (1)" }
    let(:comment_class) { Struct.new(:body, :created_at, :original_commit_id) }

    it 'says "No changes recommended" on the first review', :aggregate_failures do
      commenter.post_review(summary: summary, report: report_for([]))

      expect(client).to have_received(:add_comment).with('o/r', 1, a_string_including('**✅ No changes recommended**'))
    end

    it 'says "No new changes recommended" once Thingie has reviewed the PR before', :aggregate_failures do
      earlier = comment_class.new("#{described_class::REVIEW_COMMENT_MARKER}\n\nold", Time.utc(2026, 1, 1), 'abc1234')
      allow(client).to receive(:pull_request_comments).and_return([earlier])

      commenter.post_review(summary: summary, report: report_for([]))

      expect(client).to have_received(:add_comment)
        .with('o/r', 1, a_string_including('**✅ No new changes recommended**', 'Files reviewed (1)'))
    end
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

  it 'posts the marker once when the summary already carries it' do
    marker = Thingie::GitHub::Context::SUMMARY_MARKER
    commenter.post_review(summary: "#{marker}\n\nAll good", report: report_for([]))

    expect(client).to have_received(:add_comment) { |_repo, _pr, body| expect(body.scan(marker).size).to eq(1) }
  end

  context 'with previous summary comments' do
    let(:marker) { Thingie::GitHub::Context::SUMMARY_MARKER }
    let(:old) do
      double('comment', id: 7, node_id: 'NODE7', created_at: Time.utc(2026, 1, 1), # rubocop:disable RSpec/VerifiedDoubles
                        body: "#{marker}\n\n### Review of `abc1234`\n\nAll good")
    end
    let(:collapsed) do
      double('comment', id: 8, node_id: 'NODE8', created_at: Time.utc(2026, 1, 2), # rubocop:disable RSpec/VerifiedDoubles
                        body: '<details><summary>Outdated review</summary>')
    end

    before do
      allow(client).to receive(:issue_comments).and_return([old, collapsed])
      allow(client).to receive(:update_comment)
    end

    it 'collapses the old summary under a label naming its commit, without mentioning Thingie', :aggregate_failures do
      commenter.post_review(summary: 'S', report: report_for([]))

      expect(client).to have_received(:update_comment)
        .with('o/r', 7, a_string_starting_with('<details><summary>Outdated review of `abc1234`</summary>'))
      expect(client).not_to have_received(:update_comment).with('o/r', 8, anything)
    end

    it 'hides the collapsed summary, and only that one', :aggregate_failures do
      commenter.post_review(summary: 'S', report: report_for([]))

      expect(client).to have_received(:post)
        .with('/graphql', a_string_including('minimizeComment', 'NODE7', 'OUTDATED'))
      expect(client).not_to have_received(:post).with('/graphql', a_string_including('NODE8'))
    end

    it 'leaves no marker behind, so the next run cannot collapse it again' do
      commenter.post_review(summary: 'S', report: report_for([]))

      expect(client).to have_received(:update_comment).with('o/r', 7, satisfy { |body| !body.include?(marker) })
    end
  end

  context 'when resolving stale review threads' do
    let(:stale_thread) do
      {
        'id' => 'THREAD1', 'isResolved' => false, 'isOutdated' => true,
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

    it 'resolves a Thingie thread whose commented code changed, without needing the bot login' do
      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(client).to have_received(:post)
        .with('/graphql', a_string_including('resolveReviewThread'))
    end

    context 'when the code the thread commented on did not change' do
      let(:stale_thread) { super().merge('isOutdated' => false) }

      it 'leaves it open even though the finding was not repeated' do
        commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

        expect(client).not_to have_received(:post).with('/graphql', a_string_including('resolveReviewThread'))
      end
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

  context 'with a finding whose text is about another file' do
    let(:issue) do
      raw = Thingie::RawIssue.new(title: 'Query always returns empty', severity: 2, confidence: 2, tags: [],
                                  details: 'other.rb:17 calls a method that does not exist')
      range = Thingie::AffectedRange.new(start_line: 11, end_line: 11)
      Thingie::Issue.new(id: 1, file: 'app.rb', raw_issue: raw, affected_lines: [range])
    end

    it 'does not put it on a line, and lists it in the summary comment under the cited file', :aggregate_failures do
      commenter.post_review(summary: 'S', report: report_for([issue]))

      expect(client).not_to have_received(:create_pull_request_comment)
      expect(client).to have_received(:add_comment)
        .with('o/r', 1, a_string_including('outside this diff or about another file', '`other.rb`',
                                           'Query always returns empty'))
    end
  end

  context 'with a repeated-finding filter' do
    subject(:commenter) do
      described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, duplicate_filter: filter)
    end

    let(:filter) { instance_double(Thingie::DuplicateFilter) }
    let(:marked_body) { "#{described_class::REVIEW_COMMENT_MARKER}\n\n**[High] Old title**\n\nOld text" }
    let(:open_thread) do
      {
        'id' => 'THREAD1', 'isResolved' => false, 'isOutdated' => false, 'line' => 11, 'path' => 'app.rb',
        'comments' => { 'nodes' => [{ 'author' => { 'login' => 'bot' },
                                      'body' => marked_body }] }
      }
    end

    before do
      allow(client).to receive(:post) do |_path, body|
        if JSON.parse(body)['query'].include?('reviewThreads')
          { 'data' => { 'repository' => { 'pullRequest' => { 'reviewThreads' => { 'nodes' => [open_thread] } } } } }
        else
          {}
        end
      end
    end

    it 'hands the filter the findings and the comments that are still open', :aggregate_failures do
      issue = build_issue('app.rb', 11)
      allow(filter).to receive(:call).and_return([issue])

      commenter.post_review(summary: 'S', report: report_for([issue]))

      expect(filter).to have_received(:call)
        .with([issue], [{ file: 'app.rb', line: 11, text: "**[High] Old title**\n\nOld text" }])
      expect(client).to have_received(:create_pull_request_comment).once
    end

    it 'posts only what the filter keeps, and leaves the open thread alone', :aggregate_failures do
      allow(filter).to receive(:call).and_return([])

      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)]))

      expect(client).not_to have_received(:create_pull_request_comment)
      expect(client).not_to have_received(:post).with('/graphql', a_string_including('resolveReviewThread'))
    end

    it 'posts every finding and says so when the filter fails', :aggregate_failures do
      allow(filter).to receive(:call).and_raise(StandardError, 'model timed out')

      expect { commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11)])) }
        .to output(/Could not check for repeated findings.*model timed out/).to_stderr
      expect(client).to have_received(:create_pull_request_comment).once
    end
  end

  context 'with a repeat bar on a re-run' do
    subject(:commenter) do
      described_class.new(token: 'token', owner: 'o', repo: 'r', pr_number: 1, repeat_max_severity: 2)
    end

    let(:comment_class) { Struct.new(:body, :created_at, :original_commit_id) }
    let(:file_class) { Struct.new(:filename, :patch) }
    let(:comparison) { Struct.new(:files) }
    # app.rb line 11 was added since the last review.
    let(:since_last_review) do
      comparison.new([file_class.new('app.rb', "@@ -10,2 +10,3 @@\n ctx10\n+added11\n ctx12")])
    end
    let(:last_review_comment) do
      comment_class.new("#{described_class::REVIEW_COMMENT_MARKER}\n\nold", Time.utc(2026, 1, 1), 'last-sha')
    end

    before do
      allow(client).to receive_messages(
        pull_request_comments: [last_review_comment],
        compare: since_last_review
      )
    end

    it 'holds back a less severe finding about code that did not change', :aggregate_failures do
      expect { commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 12, severity: 3)])) }
        .to output(/Held back 1 new finding/).to_stderr
      expect(client).not_to have_received(:create_pull_request_comment)
    end

    it 'still posts a less severe finding about code that is new since the last review' do
      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 11, severity: 3)]))

      expect(client).to have_received(:create_pull_request_comment)
        .with('o/r', 1, anything, 'commit-sha', 'app.rb', 11, anything)
    end

    it 'still posts a severe finding about unchanged code' do
      commenter.post_review(summary: 'S', report: report_for([build_issue('app.rb', 12, severity: 2)]))

      expect(client).to have_received(:create_pull_request_comment)
        .with('o/r', 1, anything, 'commit-sha', 'app.rb', 12, anything)
    end
  end
end
