# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Issue do
  subject(:issue) do
    described_class.from_hash('title' => 't', 'details' => 'd', 'severity' => 2,
                              'confidence' => 3, 'tags' => [], 'file' => 'app.rb',
                              'affected_lines' => [{ 'start_line' => 1 }])
  end

  describe '#mark_unchecked' do
    it 'is off by default and survives a round trip through the report', :aggregate_failures do
      expect(issue).not_to be_unchecked
      issue.mark_unchecked
      expect(issue).to be_unchecked
      expect(described_class.from_hash(issue.to_h)).to be_unchecked
    end
  end

  describe '#apply_override' do
    it 'overrides severity and confidence when given', :aggregate_failures do
      issue.apply_override(severity: 1, confidence: 4)
      expect(issue.severity).to eq(1)
      expect(issue.confidence).to eq(4)
    end

    it 'leaves severity and confidence unchanged when nil', :aggregate_failures do
      issue.apply_override(severity: nil, confidence: nil)
      expect(issue.severity).to eq(2)
      expect(issue.confidence).to eq(3)
    end

    it 'overrides only the given field', :aggregate_failures do
      issue.apply_override(severity: 1)
      expect(issue.severity).to eq(1)
      expect(issue.confidence).to eq(3)
    end
  end

  describe 'evidence' do
    it 'round-trips through to_h and from_hash' do
      evidence = 'update only validates when amount changes (award.rb:31)'
      built = described_class.from_hash('title' => 't', 'severity' => 2, 'confidence' => 1, 'evidence' => evidence,
                                        'file' => 'a.rb', 'affected_lines' => [{ 'start_line' => 1 }])
      expect(described_class.from_hash(built.to_h).evidence).to eq(evidence)
    end

    it 'is nil when the reviewer gave none' do
      expect(issue.evidence).to be_nil
    end
  end

  describe '#cited_other_file' do
    def issue_with(details:, file: 'Gemfile.lock')
      described_class.from_hash('title' => 't', 'details' => details, 'severity' => 2, 'confidence' => 3,
                                'tags' => [], 'file' => file, 'affected_lines' => [{ 'start_line' => 18 }])
    end

    it 'is nil when the text cites no file' do
      expect(issue_with(details: 'The lock entry is stale.').cited_other_file).to be_nil
    end

    it 'is nil when the text cites the file the finding is attached to, by path or by name', :aggregate_failures do
      expect(issue_with(details: 'See Gemfile.lock:18 and app/user.rb:5').cited_other_file).to be_nil
      expect(issue_with(details: 'See config/Gemfile.lock:18').cited_other_file).to be_nil
    end

    it 'returns the cited file when the text only points at other files' do
      issue = issue_with(details: 'app/lib/stale_users.rb:17 calls user.bonuses; see app/models/user.rb:245')

      expect(issue.cited_other_file).to eq('app/lib/stale_users.rb')
    end
  end

  describe '#evidence_block' do
    def finding(evidence: nil)
      described_class.from_hash('title' => 't', 'details' => 'd', 'severity' => 2, 'confidence' => 1,
                                'tags' => [], 'file' => 'a.rb', 'evidence' => evidence,
                                'affected_lines' => [{ 'start_line' => 1 }])
    end

    it 'is nil with no evidence and no tool calls' do
      expect(finding.evidence_block).to be_nil
    end

    it 'shows the evidence alone in a collapsed block' do
      expect(finding(evidence: 'award.rb:31 skips the check').evidence_block)
        .to eq("<details><summary>Evidence</summary>\n\naward.rb:31 skips the check\n\n</details>")
    end

    it 'adds the tool calls of the second look and the review pass, repeats counted', :aggregate_failures do
      issue = finding(evidence: 'award.rb:31 skips the check')
      issue.record_tool_calls(review: ['search a', 'search a', 'file b.rb'], critic: ['symbol Award'])
      block = issue.evidence_block

      expect(block).to start_with('<details><summary>Evidence</summary>')
      expect(block).to include('award.rb:31 skips the check',
                               "Tool calls, second look (1):\n\n```text\nsymbol Award\n```",
                               "Tool calls, review pass over this file (3):\n\n```text\nsearch a (x2)\nfile b.rb\n```")
      expect(block.index('Second look'.downcase)).to be < block.index('review pass')
    end

    it 'shows the tool calls even when the reviewer gave no evidence' do
      issue = finding
      issue.record_tool_calls(critic: ['search a'])

      expect(issue.evidence_block).to include('Tool calls, second look (1)')
    end

    it 'caps a long list and says how many were left out', :aggregate_failures do
      issue = finding
      issue.record_tool_calls(review: (1..30).map { |n| "search term#{n}" })
      block = issue.evidence_block

      expect(block).to include('search term25', '... and 5 more')
      expect(block).not_to include('search term26')
    end

    it 'survives a round trip through the report file' do
      issue = finding
      issue.record_tool_calls(review: ['search a'], critic: ['file b.rb'])
      copy = described_class.from_hash(issue.to_h)

      expect([copy.review_tool_calls, copy.critic_tool_calls]).to eq([['search a'], ['file b.rb']])
    end
  end

  describe '#details_markdown' do
    def with_details(details)
      described_class.from_hash('title' => 't', 'details' => details, 'severity' => 2, 'confidence' => 1,
                                'tags' => [], 'file' => 'a.rb', 'affected_lines' => [{ 'start_line' => 1 }])
    end

    it 'puts each labelled part on its own paragraph', :aggregate_failures do
      run_together = "**What's wrong:** It crashes. **When it happens:** On a new user. **Fix:** Skip them."

      expect(with_details(run_together).details_markdown)
        .to eq("**What's wrong:** It crashes.\n\n**When it happens:** On a new user.\n\n**Fix:** Skip them.")
    end

    it 'leaves parts that are already separate alone' do
      separate = "**What's wrong:** It crashes.\n\n**When it happens:** On a new user.\n\n**Fix:** Skip them."

      expect(with_details(separate).details_markdown).to eq(separate)
    end

    it 'does not split at a label name that is quoted in backticks', :aggregate_failures do
      quoted = "**What's wrong:** It hardcodes the labels `**When it happens:**` and `**Fix:**`. " \
               '**When it happens:** Someone renames one. **Fix:** Share the labels.'

      expect(with_details(quoted).details_markdown).to eq(
        "**What's wrong:** It hardcodes the labels `**When it happens:**` and `**Fix:**`.\n\n" \
        "**When it happens:** Someone renames one.\n\n**Fix:** Share the labels."
      )
    end

    it 'leaves details in any other shape untouched', :aggregate_failures do
      expect(with_details('It crashes for a new user.').details_markdown).to eq('It crashes for a new user.')
      expect(with_details(nil).details_markdown).to be_nil
    end
  end
end
