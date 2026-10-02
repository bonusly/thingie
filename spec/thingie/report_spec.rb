# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Report do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:target) do
    Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: 'abc',
                              branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'round-trips the run details through the saved JSON with string keys', :aggregate_failures do
    described_class.new(target: target, model: 'm', details: { source: 'claude_code', turns: 3 }).save(tmp_dir)
    loaded = described_class.from_file(File.join(tmp_dir, 'code-review-report.json'))
    expect(loaded.details).to eq('source' => 'claude_code', 'turns' => 3)
    expect(loaded.model).to eq('m')
  end

  it 'reads a report saved before details existed' do
    report = described_class.from_hash('target' => target.to_h.transform_keys(&:to_s), 'model' => 'm', 'issues' => [])
    expect(report.details).to eq({})
  end

  it 'treats nil details as none' do
    expect(described_class.new(target: target, model: 'm', details: nil).details).to eq({})
  end
end
