# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::IssueParser do
  let(:finding) do
    { 'title' => 'Guard skipped', 'details' => 'd', 'evidence' => 'award.rb:31 skips the check', 'tags' => ['bug'],
      'severity' => 2, 'confidence' => 1, 'affected_lines' => [{ 'start_line' => 31 }] }
  end

  it 'keeps the evidence the reviewer gave' do
    expect(described_class.new.parse([finding], 'award.rb').first.evidence).to eq('award.rb:31 skips the check')
  end

  it 'accepts a finding with no evidence' do
    expect(described_class.new.parse([finding.except('evidence')], 'award.rb').first.evidence).to be_nil
  end

  it 'requires evidence in the response schema, as strict structured output demands every property' do
    item = Thingie::Schemas::ISSUE_SCHEMA[:schema][:properties][:issues][:items]
    expect(item[:required]).to include('evidence')
  end
end
