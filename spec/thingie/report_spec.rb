# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Report do
  let(:target) do
    Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
                              branch: nil, base_ref: nil, head_ref: nil, merge_base: false)
  end

  it 'is balanced unless told otherwise' do
    expect(described_class.new(target: target, model: 'm').profile).to eq('balanced')
  end

  it 'keeps its profile through a saved report', :aggregate_failures do
    report = described_class.new(target: target, model: 'm', profile: 'fast')

    expect(report.to_h['profile']).to eq('fast')
    expect(described_class.from_hash(report.to_h).profile).to eq('fast')
  end

  it 'reads a report saved before profiles existed as balanced' do
    expect(described_class.from_hash('target' => {}, 'model' => 'm').profile).to eq('balanced')
  end
end
