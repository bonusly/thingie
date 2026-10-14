# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Report do
  let(:target) do
    Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
                              branch: nil, base_ref: nil, head_ref: nil, merge_base: false)
  end

  it 'carries the files that got no review, and reads an older report as having none', :aggregate_failures do
    report = described_class.new(target: target, model: 'm', unreviewed_files: ['app.rb'])

    expect(described_class.from_hash(report.to_h).unreviewed_files).to eq(['app.rb'])
    expect(described_class.from_hash('target' => {}, 'model' => 'm').unreviewed_files).to eq([])
  end

  it 'carries the held-back findings, and reads an older report as having none', :aggregate_failures do
    held = Thingie::Issue.from_hash('title' => 'Maybe', 'severity' => 3, 'confidence' => 3, 'file' => 'app.rb')
    report = described_class.new(target: target, model: 'm', held_back_issues: [held])

    expect(described_class.from_hash(report.to_h).held_back_issues.map(&:title)).to eq(['Maybe'])
    expect(described_class.from_hash('target' => {}, 'model' => 'm').held_back_issues).to eq([])
  end
end
