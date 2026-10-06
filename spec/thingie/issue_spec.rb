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
end
