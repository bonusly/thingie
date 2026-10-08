# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::RepeatBar do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:bar) do
    described_class.new(client: client, repo: 'o/r', pr_number: 1, max_severity: max_severity, marker: marker)
  end

  let(:client) { instance_double(Octokit::Client) }
  let(:marker) { '<!-- thingie-review-comment -->' }
  let(:max_severity) { 2 }
  let(:comment_class) { Struct.new(:body, :created_at, :original_commit_id) }
  let(:file_class) { Struct.new(:filename, :patch) }
  let(:comparison) { Struct.new(:files) }
  let(:previous_comments) do
    [comment_class.new("#{marker}\n\nold", Time.utc(2026, 1, 1), 'old-sha'),
     comment_class.new("#{marker}\n\nnewer", Time.utc(2026, 1, 2), 'last-sha'),
     comment_class.new('a human comment', Time.utc(2026, 1, 3), 'human-sha')]
  end
  # Line 20 of a.rb was added since the last review; lines 19 and 21 are context.
  let(:patch) { "@@ -19,2 +19,3 @@\n ctx19\n+added20\n ctx21" }

  def finding(title, severity:, line:, file: 'a.rb', details: 'd')
    Thingie::Issue.from_hash('title' => title, 'details' => details, 'severity' => severity, 'confidence' => 1,
                             'tags' => [], 'file' => file, 'affected_lines' => [{ 'start_line' => line }])
  end

  before do
    allow(Warning).to receive(:warn) # the bar reports what it holds back with Kernel#warn
    allow(client).to receive_messages(pull_request_comments: previous_comments, issue_comments: [],
                                      compare: comparison.new([file_class.new('a.rb', patch)]))
  end

  it 'posts everything when it is not a re-run', :aggregate_failures do
    allow(client).to receive(:pull_request_comments).and_return([])
    issues = [finding('minor', severity: 3, line: 10)]

    expect(bar.call(issues, 'head-sha')).to eq(issues)
    expect(client).not_to have_received(:compare)
  end

  it 'posts everything when no bar is configured' do
    issues = [finding('minor', severity: 4, line: 10)]

    expect(described_class.new(client: client, repo: 'o/r', pr_number: 1, max_severity: nil, marker: marker)
      .call(issues, 'head-sha')).to eq(issues)
  end

  describe '#reviewed_before?' do
    it 'is false when Thingie has not commented yet' do
      allow(client).to receive_messages(pull_request_comments: [], issue_comments: [])

      expect(bar.reviewed_before?).to be(false)
    end

    it 'is false when GitHub cannot be asked' do
      allow(client).to receive(:pull_request_comments).and_raise(Octokit::ServerError)

      expect(bar.reviewed_before?).to be(false)
    end
  end

  context 'when it is a re-run' do
    let(:minor_on_old_code) { finding('minor, old code', severity: 3, line: 10) }
    let(:severe_on_old_code) { finding('severe, old code', severity: 2, line: 10) }
    let(:minor_on_new_code) { finding('minor, new code', severity: 3, line: 20) }
    let(:minor_in_new_file) { finding('minor, new file', severity: 4, line: 1, file: 'b.rb') }

    it 'holds back a less severe finding about code that did not change since the last review' do
      expect(bar.call([minor_on_old_code], 'head-sha')).to eq([])
    end

    it 'keeps a severe finding about unchanged code' do
      expect(bar.call([severe_on_old_code], 'head-sha')).to eq([severe_on_old_code])
    end

    it 'keeps a less severe finding about lines added since the last review' do
      expect(bar.call([minor_on_new_code], 'head-sha')).to eq([minor_on_new_code])
    end

    it 'keeps a less severe finding in a file added since the last review' do
      allow(client).to receive(:compare)
        .and_return(comparison.new([file_class.new('b.rb', "@@ -0,0 +1,3 @@\n+one\n+two\n+three")]))

      expect(bar.call([minor_in_new_file], 'head-sha')).to eq([minor_in_new_file])
    end

    it 'compares against the commit of the newest Thingie comment, not a human one' do
      bar.call([minor_on_old_code], 'head-sha')

      expect(client).to have_received(:compare).with('o/r', 'last-sha', 'head-sha')
    end

    it 'holds back less severe findings without asking GitHub when nothing was pushed', :aggregate_failures do
      expect(bar.call([minor_on_old_code, minor_on_new_code], 'last-sha')).to eq([])
      expect(client).not_to have_received(:compare)
    end

    it 'says which findings it held back' do
      bar.call([minor_on_old_code], 'head-sha')

      expect(Warning).to have_received(:warn).with(/Held back 1 new finding.*above 2.*minor, old code/, any_args)
    end

    it 'posts everything and says so when the changes cannot be fetched', :aggregate_failures do
      allow(client).to receive(:compare).and_raise(Octokit::NotFound)
      issues = [minor_on_old_code]

      expect(bar.call(issues, 'head-sha')).to eq(issues)
      expect(Warning).to have_received(:warn).with(/Could not tell what changed since the last review/, any_args)
    end

    context 'when the last review posted only a summary comment' do
      let(:summary_class) { Struct.new(:body, :created_at) }
      let(:summary) do
        body = "### Review of `abc1234`\n\nNo issues.\n\n#{Thingie::GitHub::Context::SUMMARY_MARKER}"
        summary_class.new(body, Time.utc(2026, 1, 5))
      end

      before do
        allow(client).to receive_messages(pull_request_comments: [], issue_comments: [summary])
      end

      it 'counts it as the last review, so the bar still applies', :aggregate_failures do
        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([])
        expect(client).to have_received(:compare).with('o/r', 'abc1234', 'head-sha')
      end

      it 'reads a summary that a later run collapsed' do
        prefix = Thingie::GitHub::Commenter::OUTDATED_PREFIX
        body = "#{prefix} of `abc1234`</summary>\n\n### Review of `abc1234`\n\n</details>"
        collapsed = summary_class.new(body, Time.utc(2026, 1, 5))
        allow(client).to receive(:issue_comments).and_return([collapsed])

        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([])
      end

      it 'knows Thingie has reviewed the PR before' do
        expect(bar.reviewed_before?).to be(true)
      end

      it 'uses the newest review when there are inline comments and summaries', :aggregate_failures do
        allow(client).to receive(:pull_request_comments).and_return(previous_comments)

        bar.call([minor_on_old_code], 'head-sha')

        expect(client).to have_received(:compare).with('o/r', 'abc1234', 'head-sha')
      end

      it 'ignores a comment from someone else that mentions a review' do
        human = summary_class.new('Review of `fffffff` looks fine to me', Time.utc(2026, 2, 1))
        allow(client).to receive(:issue_comments).and_return([human])

        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([minor_on_old_code])
      end
    end

    context 'with a finding whose text is about another file' do
      # The finding is attached to Gemfile.lock but its line numbers belong to app/lib/x.rb, where only
      # line 20 was added since the last review.
      let(:cited_patch) { "@@ -19,2 +19,3 @@\n ctx19\n+added20\n ctx21" }

      before do
        files = [file_class.new('app/lib/x.rb', cited_patch), file_class.new('Gemfile.lock', "@@ -1 +1 @@\n+one")]
        allow(client).to receive(:compare).and_return(comparison.new(files))
      end

      def cross_file(line, cited: 'app/lib/x.rb')
        details = "#{cited}:#{line} calls a missing method"
        finding('cross', severity: 3, line: line, file: 'Gemfile.lock', details: details)
      end

      it 'keeps the normal bar when the cited file has a new line there' do
        issue = cross_file(20)

        expect(bar.call([issue], 'head-sha')).to eq([issue])
      end

      it 'holds the finding back when the cited file did not change there', :aggregate_failures do
        expect(bar.call([cross_file(10)], 'head-sha')).to eq([])
      end

      it 'matches a file cited by its bare name' do
        issue = cross_file(20, cited: 'x.rb')

        expect(bar.call([issue], 'head-sha')).to eq([issue])
      end

      it 'keeps the normal bar when the cited file cannot be matched to a changed file' do
        issue = cross_file(10, cited: 'app/lib/unknown.rb')

        expect(bar.call([issue], 'head-sha')).to eq([issue])
      end
    end

    context 'when GitHub cannot say what changed' do
      it 'keeps the normal bar for a file whose diff it left out' do
        allow(client).to receive(:compare).and_return(comparison.new([file_class.new('a.rb', nil)]))

        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([minor_on_old_code])
      end

      it 'still holds back a finding in a file whose diff it did list' do
        allow(client).to receive(:compare)
          .and_return(comparison.new([file_class.new('a.rb', patch), file_class.new('big.bin', nil)]))

        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([])
      end

      it 'posts everything when the change has more files than GitHub lists', :aggregate_failures do
        files = Array.new(300) { |n| file_class.new("f#{n}.rb", patch) }
        allow(client).to receive(:compare).and_return(comparison.new(files))

        expect(bar.call([minor_on_old_code], 'head-sha')).to eq([minor_on_old_code])
        expect(Warning).to have_received(:warn).with(/300 or more files/, any_args)
      end
    end
  end
end
