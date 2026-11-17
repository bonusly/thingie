# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'thingie/cli'
require 'fileutils'

RSpec.describe Thingie::CLI do
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  context 'when running approve with approve and stats enabled' do
    let(:sink_path) { File.join(tmp_dir, 'stats.jsonl') }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: { 'approve' => { 'enabled' => true },
                     'stats' => { 'enabled' => true, 'sinks' => [{ 'type' => 'jsonl', 'path' => sink_path }] } }
      )
    end
    let(:fake_approver) { instance_double(Thingie::GitHub::Approver) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::GitHub::Approver).to receive(:new).and_return(fake_approver)
      allow(fake_approver).to receive(:run)
        .and_return(Thingie::GitHub::Approver::Decision.new(:block, ['a reason']))
      Thingie::Env['GITHUB_TOKEN'] = 'token'
    end

    it 'builds the approver for the PR' do
      described_class.start(['approve', '--pr', '42', '--gh-repo', 'o/r'])

      expect(Thingie::GitHub::Approver).to have_received(:new)
        .with(hash_including(token: 'token', owner: 'o', repo: 'r', pr_number: 42))
    end

    it 'emits an approval.decided stats line with the block reason', :aggregate_failures do
      described_class.start(['approve', '--pr', '42', '--gh-repo', 'o/r'])

      events = File.readlines(sink_path).map { |line| JSON.parse(line) }
      expect(events.size).to eq(1)
      event = events.first
      expect(event['event']).to eq('approval.decided')
      expect(event['action']).to eq('block')
      expect(event['reasons']).to eq(['a reason'])
      expect(event['repo']).to eq('o/r')
      expect(event['pr_number']).to eq(42)
      expect(event['dry_run']).to be(false)
    end
  end

  context 'when running approve with approve disabled, its default' do
    before do
      allow(Thingie::Configuration).to receive(:new).and_return(Thingie::Configuration.new(root: tmp_dir))
      allow(Thingie::GitHub::Approver).to receive(:new)
    end

    it 'does nothing' do
      described_class.start(['approve', '--pr', '42', '--gh-repo', 'o/r'])

      expect(Thingie::GitHub::Approver).not_to have_received(:new)
    end
  end
end
