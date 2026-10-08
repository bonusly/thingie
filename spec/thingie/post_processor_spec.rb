# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::PostProcessor do
  def issue(confidence:, severity:)
    instance_double(Thingie::Issue, confidence: confidence, severity: severity)
  end

  let(:issues) do
    [issue(confidence: 1, severity: 2), issue(confidence: 2, severity: 2), issue(confidence: 1, severity: 4)]
  end

  # Severity is capped before the critic pass, confidence after it.
  def filter(settings, findings)
    processor = described_class.new(settings)
    processor.cap_confidence(processor.call(findings))
  end

  it 'caps severity in #call and leaves confidence for #cap_confidence', :aggregate_failures do
    processor = described_class.new('max_confidence' => 1, 'max_severity' => 3)

    expect(processor.call(issues)).to eq(issues.first(2))
    expect(processor.cap_confidence(issues.first(2))).to eq([issues.first])
  end

  it 'keeps only issues within the confidence and severity maximums' do
    expect(filter({ 'max_confidence' => 1, 'max_severity' => 3 }, issues)).to eq([issues.first])
  end

  it 'keeps everything when no thresholds are configured' do
    expect(filter(nil, issues)).to eq(issues)
  end

  context 'with require_evidence' do
    def finding(confidence:, evidence:)
      Thingie::Issue.from_hash('title' => 't', 'severity' => 2, 'confidence' => confidence, 'evidence' => evidence,
                               'file' => 'a.rb', 'affected_lines' => [{ 'start_line' => 1 }])
    end

    let(:verified) { finding(confidence: 1, evidence: 'award.rb:31 skips the check') }
    let(:unverified) { finding(confidence: 1, evidence: ' ') }

    it 'grades a finding without evidence as unverified, so a stricter max_confidence drops it', :aggregate_failures do
      kept = filter({ 'max_confidence' => 2, 'require_evidence' => true }, [verified, unverified])
      expect(kept).to eq([verified])
      expect(unverified.confidence).to eq(3)
    end

    it 'never raises a finding that is already below the unverified grade' do
      weak = finding(confidence: 4, evidence: nil)
      described_class.new('require_evidence' => true).cap_confidence([weak])
      expect(weak.confidence).to eq(4)
    end

    it 'holds a finding with no evidence back even when the critic grades it highly', :aggregate_failures do
      processor = described_class.new('max_confidence' => 2, 'require_evidence' => true)
      survivors = processor.call([verified, unverified])
      unverified.apply_override(confidence: 1) # the critic's grade, set after the first pass

      expect(processor.cap_confidence(survivors)).to eq([verified])
      expect(unverified.confidence).to eq(3)
    end

    it 'uses the configured unverified grade' do
      kept = filter({ 'max_confidence' => 2, 'require_evidence' => true, 'unverified_confidence' => 2 }, [unverified])
      expect(kept).to eq([unverified])
    end

    it 'leaves confidence alone when the option is off', :aggregate_failures do
      kept = filter({ 'max_confidence' => 2 }, [verified, unverified])
      expect(kept).to eq([verified, unverified])
      expect(unverified.confidence).to eq(1)
    end
  end
end
