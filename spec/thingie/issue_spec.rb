# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Issue do
  subject(:issue) do
    described_class.from_hash('title' => 't', 'details' => 'd', 'severity' => 2,
                              'confidence' => 3, 'tags' => [], 'file' => 'app.rb',
                              'affected_lines' => [{ 'start_line' => 1 }])
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
end
