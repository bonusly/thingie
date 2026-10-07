# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::PostProcessor do
  def issue(confidence:, severity:)
    instance_double(Thingie::Issue, confidence: confidence, severity: severity)
  end

  let(:issues) do
    [issue(confidence: 1, severity: 2), issue(confidence: 2, severity: 2), issue(confidence: 1, severity: 4)]
  end

  it 'keeps only issues within the confidence and severity maximums' do
    kept = described_class.new('max_confidence' => 1, 'max_severity' => 3).call(issues)
    expect(kept).to eq([issues.first])
  end

  it 'keeps everything when no thresholds are configured' do
    expect(described_class.new(nil).call(issues)).to eq(issues)
  end

  context 'with confidence_after_verify' do
    subject(:processor) do
      described_class.new('max_confidence' => 1, 'max_severity' => 3, 'confidence_after_verify' => true)
    end

    it 'filters on severity first and leaves confidence for after the critic', :aggregate_failures do
      expect(processor.call(issues)).to eq(issues.first(2))
      expect(processor.cap_confidence(issues.first(2))).to eq([issues.first])
    end

    it 'cap_confidence changes nothing when the cap is applied before the critic' do
      before_critic = described_class.new('max_confidence' => 1)

      expect(before_critic.cap_confidence(issues)).to eq(issues)
    end
  end

  context 'with require_evidence' do
    def finding(confidence:, evidence:)
      Thingie::Issue.from_hash('title' => 't', 'severity' => 2, 'confidence' => confidence, 'evidence' => evidence,
                               'file' => 'a.rb', 'affected_lines' => [{ 'start_line' => 1 }])
    end

    let(:verified) { finding(confidence: 1, evidence: 'award.rb:31 skips the check') }
    let(:unverified) { finding(confidence: 1, evidence: ' ') }

    it 'grades a finding without evidence as unverified, so a stricter max_confidence drops it', :aggregate_failures do
      kept = described_class.new('max_confidence' => 2, 'require_evidence' => true).call([verified, unverified])
      expect(kept).to eq([verified])
      expect(unverified.confidence).to eq(3)
    end

    it 'never raises a finding that is already below the unverified grade' do
      weak = finding(confidence: 4, evidence: nil)
      described_class.new('require_evidence' => true).call([weak])
      expect(weak.confidence).to eq(4)
    end

    it 'uses the configured unverified grade' do
      kept = described_class.new('max_confidence' => 2, 'require_evidence' => true,
                                 'unverified_confidence' => 2).call([unverified])
      expect(kept).to eq([unverified])
    end

    it 'leaves confidence alone when the option is off', :aggregate_failures do
      kept = described_class.new('max_confidence' => 2).call([verified, unverified])
      expect(kept).to eq([verified, unverified])
      expect(unverified.confidence).to eq(1)
    end
  end
end
