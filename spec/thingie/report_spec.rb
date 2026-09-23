# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Thingie::Report do
  let(:target) do
    Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 1, commit_sha: nil,
                              branch: nil, base_ref: nil, head_ref: nil, merge_base: false)
  end

  def round_trip(report)
    described_class.from_hash(JSON.parse(JSON.generate(report.to_h)))
  end

  describe 'unreviewed files' do
    # `github-comment` runs as a separate step and loads the report from disk,
    # so the approver only sees an incomplete run if this survives the file.
    it 'survives the JSON round trip' do
      report = described_class.new(target: target, model: 'm', unreviewed_files: ['a.rb', 'b.rb'])

      expect(round_trip(report).unreviewed_files).to eq(['a.rb', 'b.rb'])
    end

    it 'is empty for a run that reviewed everything' do
      expect(round_trip(described_class.new(target: target, model: 'm')).unreviewed_files).to eq([])
    end

    it 'does not double-count a file that failed more than once' do
      report = described_class.new(target: target, model: 'm', unreviewed_files: ['a.rb', 'a.rb'])

      expect(report.unreviewed_files).to eq(['a.rb'])
    end

    # A report written by an older Thingie has no such key. It reads as
    # complete, which is the pre-existing behavior rather than a new hole:
    # both steps of a run use the same version.
    it 'defaults to empty when the key is absent' do
      data = JSON.parse(JSON.generate(described_class.new(target: target, model: 'm').to_h))
      data.delete('unreviewed_files')

      expect(described_class.from_hash(data).unreviewed_files).to eq([])
    end
  end
end
