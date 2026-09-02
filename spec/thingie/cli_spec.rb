# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'thingie/cli'
require 'fileutils'

RSpec.describe Thingie::CLI do
  let(:tmp_dir) { Dir.mktmpdir }

  # Keep the global RubyLLM registry hermetic across examples.
  around do |example|
    original_file = RubyLLM.config.model_registry_file
    original_key = RubyLLM.config.openai_api_key
    example.run
  ensure
    RubyLLM.config.model_registry_file = original_file
    RubyLLM.config.openai_api_key = original_key
    RubyLLM::Models.instance_variable_set(:@instance, nil)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def run_models(argv)
    Thingie::CLI.start(['models', *argv])
  end

  context 'when no models_file is configured' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'models_file' => '' }) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(RubyLLM.models).to receive(:refresh!)
    end

    it 'exits with a usage message and does not call refresh' do
      expect do
        run_models([])
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(RubyLLM.models).not_to have_received(:refresh!)
    end
  end

  context 'when --path is given' do
    let(:models_path) { File.join(tmp_dir, 'nested', 'models.json') }
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'models_file' => models_path }) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(RubyLLM.models).to receive(:refresh!)
      allow(RubyLLM.models).to receive(:save_to_json)
      allow(RubyLLM.models).to receive(:count).and_return(7)
    end

    it 'refreshes the registry and saves it to the configured path' do
      expect do
        run_models(['--path', models_path])
      end.to output(/Saved 7 models to #{Regexp.escape(models_path)}/).to_stdout

      expect(RubyLLM.models).to have_received(:refresh!).with(no_args)
      expect(RubyLLM.models).to have_received(:save_to_json).with(models_path)
      expect(RubyLLM.config.model_registry_file).to eq(models_path)
      expect(File.exist?(File.dirname(models_path))).to be(true)
    end
  end

  context 'when running a review with stats enabled' do
    let(:sink_path) { File.join(tmp_dir, 'stats.jsonl') }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: { 'stats' => { 'enabled' => true, 'sinks' => [{ 'type' => 'jsonl', 'path' => sink_path }] } }
      )
    end
    let(:usage) { Thingie::Stats::Usage.new }
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: 'deadbeef',
                                         branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: 1)
    end
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, files: ['a.rb'], workdir: tmp_dir, base_ref: 'main', head_ref: 'HEAD')
    end
    let(:fake_reviewer) do
      instance_double(Thingie::Reviewer, review: report, usage: usage)
    end

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::Changeset).to receive(:new).and_return(fake_changeset)
      allow(Thingie::Reviewer).to receive(:new).and_return(fake_reviewer)
      allow(Thingie::LlmClient).to receive(:new)
      allow(Thingie::SkillCatalog).to receive(:tool).and_return(nil)
    end

    def run_review
      Thingie::CLI.start(['review'])
    end

    it 'emits a review.completed stats line to the configured sink', :aggregate_failures do
      run_review

      events = File.readlines(sink_path).map { |line| JSON.parse(line) }
      expect(events.size).to eq(1)
      event = events.first
      expect(event['event']).to eq('review.completed')
      expect(event['commit_sha']).to eq('deadbeef')
      expect(event['model']).to eq('m')
      expect(event['files_reviewed']).to eq(1)
      expect(event['duration_ms']).to be_an(Integer)
      expect(event['usage']).to eq(usage.to_h)
    end
  end

  context 'when running github-comment with approve and stats enabled' do
    let(:sink_path) { File.join(tmp_dir, 'stats.jsonl') }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: { 'approve' => { 'enabled' => true },
                     'stats' => { 'enabled' => true, 'sinks' => [{ 'type' => 'jsonl', 'path' => sink_path }] } }
      )
    end
    let(:md_path) { File.join(tmp_dir, 'code-review-report.md') }
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 42, commit_sha: 'deadbeef',
                                         branch: 'feat', base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: 1)
    end
    let(:fake_commenter) { instance_double(Thingie::GitHub::Commenter, post_review: nil) }
    let(:fake_approver) { instance_double(Thingie::GitHub::Approver) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::GitHub::Commenter).to receive(:new).and_return(fake_commenter)
      allow(Thingie::GitHub::Approver).to receive(:new).and_return(fake_approver)
      allow(fake_approver).to receive(:run)
        .and_return(Thingie::GitHub::Approver::Decision.new(:block, ['a reason']))
      report.save(tmp_dir)
      File.write(md_path, 'summary')
      allow(Thingie::Env).to receive(:fetch).and_call_original
      allow(Thingie::Env).to receive(:fetch).with('GITHUB_TOKEN', nil).and_return('token')
    end

    def run_github_comment
      Thingie::CLI.start(['github-comment', '--md-report-file', md_path, '--pr', '42', '--gh-repo', 'o/r'])
    end

    it 'emits an approval.decided stats line with the block reason', :aggregate_failures do
      run_github_comment

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

    # special_sauce#26652: a rate-limited comment post raised out of the
    # posting step, approval was never evaluated, and the run left no decision
    # on the PR and no approval.decided event anywhere.
    context 'when posting the review fails' do
      before { allow(fake_commenter).to receive(:post_review).and_raise(StandardError, 'secondary rate limit') }

      it 'still evaluates approval and records the decision', :aggregate_failures do
        expect { run_github_comment }.to raise_error(SystemExit)

        expect(fake_approver).to have_received(:run)
        events = File.readlines(sink_path).map { |line| JSON.parse(line) }
        expect(events.map { |event| event['event'] }).to eq(['approval.decided'])
      end

      # Evaluating is not the same as approving: findings nobody can see must
      # not be approved past, so the approver is told the review never landed.
      it 'tells the approver the review did not reach the PR' do
        expect { run_github_comment }.to raise_error(SystemExit)

        expect(fake_approver).to have_received(:run).with(anything, review_posted: false)
      end

      it 'still fails the command so the broken post stays visible' do
        expect { run_github_comment }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    # A log scan for the special_sauce#26652 incident class (posting failed)
    # must not also match an unrelated approval-evaluation failure — they
    # need distinct messages, or the incident's log signal is ambiguous.
    #
    # run_github_comment raises SystemExit (exit 1) on this path — it must be
    # rescued *inside* the block passed to expect {}, not around the whole
    # example. output(...).to_stderr captures $stderr only while its block
    # runs; letting SystemExit escape that block skips the matcher's own
    # assertion entirely; a rescue around the whole `it` would then silently
    # swallow that, and the example would pass no matter what was printed.
    context 'when approval evaluation itself fails, unrelated to posting' do
      before { allow(fake_approver).to receive(:run).and_raise(StandardError, 'bad config') }

      def run_github_comment_swallowing_exit
        run_github_comment
      rescue SystemExit
        nil
      end

      it 'reports it as a command failure, not a posting failure' do
        expect { run_github_comment_swallowing_exit }.to output(/Thingie github-comment failed: bad config/).to_stderr
      end

      it 'does not print the posting-failure message for an unrelated error' do
        expect { run_github_comment_swallowing_exit }.not_to output(/GitHub comment failed/).to_stderr
      end
    end
  end

  context 'when running dismiss-approvals with approve enabled' do
    let(:config) do
      Thingie::Configuration.new(root: tmp_dir, overrides: { 'approve' => { 'enabled' => true } })
    end
    let(:fake_approver) { instance_double(Thingie::GitHub::Approver) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::GitHub::Approver).to receive(:new).and_return(fake_approver)
      allow(fake_approver).to receive(:dismiss_existing_approvals)
      allow(Thingie::Env).to receive(:fetch).and_call_original
      allow(Thingie::Env).to receive(:fetch).with('GITHUB_TOKEN', nil).and_return('token')
    end

    it 'dismisses existing approvals on the PR' do
      described_class.start(['dismiss-approvals', '--pr', '42', '--gh-repo', 'o/r'])

      expect(fake_approver).to have_received(:dismiss_existing_approvals)
    end
  end
end
