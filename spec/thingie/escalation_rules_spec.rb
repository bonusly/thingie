# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::EscalationRules do
  subject(:rules) { described_class.new(entries) }

  let(:entries) do
    [{ 'threshold' => 0.5, 'label' => 'risk: needs review' }, { 'threshold' => 0.8, 'label' => 'risk: high' }]
  end

  describe '#labels_for' do
    it 'includes every rule the score reaches, including a score equal to the threshold' do
      expect(rules.labels_for(0.8)).to eq(['risk: needs review', 'risk: high'])
    end

    it 'leaves out rules the score stops short of' do
      expect(rules.labels_for(0.6)).to eq(['risk: needs review'])
    end

    it 'is empty when no rule matches' do
      expect(rules.labels_for(0.49)).to be_empty
    end

    it 'lists a label shared by two rules once' do
      shared = described_class.new([{ 'threshold' => 0.2, 'label' => 'risk' },
                                    { 'threshold' => 0.4, 'label' => 'risk' }])

      expect(shared.labels_for(0.9)).to eq(['risk'])
    end
  end

  describe '#matching' do
    it 'carries the configured title and description, and leaves out blank ones', :aggregate_failures do
      described = described_class.new([{ 'threshold' => 0.5, 'label' => 'risk', 'title' => 'Needs review',
                                         'description' => 'Read it.' },
                                       { 'threshold' => 0.7, 'label' => 'high', 'title' => ' ' }])

      expect(described.matching(0.8)).to eq([{ 'label' => 'risk', 'title' => 'Needs review',
                                               'description' => 'Read it.' },
                                             { 'label' => 'high' }])
    end

    it 'keeps the first rule when two share a label' do
      shared = described_class.new([{ 'threshold' => 0.2, 'label' => 'risk', 'title' => 'First' },
                                    { 'threshold' => 0.4, 'label' => 'risk', 'title' => 'Second' }])

      expect(shared.matching(0.9)).to eq([{ 'label' => 'risk', 'title' => 'First' }])
    end
  end

  describe '#managed_labels' do
    it 'lists every rule label whether or not a score reaches it' do
      expect(rules.managed_labels).to eq(['risk: needs review', 'risk: high'])
    end
  end

  describe '#empty?' do
    it 'is true without rules' do
      expect(described_class.new(nil)).to be_empty
    end
  end

  describe 'validation' do
    it 'rejects a threshold outside 0 to 1' do
      expect { described_class.new([{ 'threshold' => 5, 'label' => 'x' }]) }
        .to raise_error(Thingie::ConfigurationError, /threshold/)
    end

    it 'rejects a blank label' do
      expect { described_class.new([{ 'threshold' => 0.5, 'label' => ' ' }]) }
        .to raise_error(Thingie::ConfigurationError, /label/)
    end

    it 'rejects a single [escalations] table instead of a list of tables' do
      expect { described_class.new({ 'threshold' => 0.5, 'label' => 'x' }) }
        .to raise_error(Thingie::ConfigurationError, /list of \[\[escalations\]\] tables/)
    end
  end
end
