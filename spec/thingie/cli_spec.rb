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

  context 'when running a review of a large PR' do
    let(:config) do
      Thingie::Configuration.new(root: tmp_dir, overrides: { 'large_pr' => large_pr })
    end
    let(:large_pr) { { 'model' => 'fast-model' } }
    let(:files) { %w[a.rb b.rb c.rb] }
    let(:changes) { 600 }
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: 'deadbeef',
                                         branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: files.size)
    end
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, files: files, workdir: tmp_dir, base_ref: 'main', head_ref: 'HEAD',
                                          changed_line_count: changes)
    end
    let(:fake_reviewer) { instance_double(Thingie::Reviewer, review: report, usage: Thingie::Stats::Usage.new) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::Changeset).to receive(:new).and_return(fake_changeset)
      allow(Thingie::Reviewer).to receive(:new).and_return(fake_reviewer)
      allow(Thingie::LlmClient).to receive(:new)
      allow(Thingie::SkillCatalog).to receive(:tool).and_return(nil)
    end

    def run_review(*args)
      Thingie::CLI.start(['review', *args])
    end

    it 'reviews on the faster model and records the fast profile', :aggregate_failures do
      run_review

      expect(Thingie::Reviewer).to have_received(:new).with(hash_including(profile: 'fast'))
      expect(Thingie::Configuration).to have_received(:new).with(overrides: { model: 'fast-model' })
    end

    context 'with no more changed lines than [approve] max_changes' do
      let(:changes) { 500 }

      it 'keeps the balanced profile and the review model' do
        run_review

        expect(Thingie::Reviewer).to have_received(:new).with(hash_including(profile: 'balanced'))
      end
    end

    context 'with no faster model set' do
      let(:large_pr) { {} }

      it 'keeps the balanced profile, so nothing changes' do
        run_review

        expect(Thingie::Reviewer).to have_received(:new).with(hash_including(profile: 'balanced'))
      end
    end

    context 'when there is no PR to size, as in --all mode' do
      let(:changes) { nil }

      it 'never switches' do
        run_review

        expect(Thingie::Reviewer).to have_received(:new).with(hash_including(profile: 'balanced'))
      end
    end

    it 'keeps the model chosen on the command line' do
      run_review('--model', 'chosen')

      expect(Thingie::Reviewer).to have_received(:new).with(hash_including(profile: 'balanced'))
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
  end

  context 'when running github-comment and building the repeat check' do
    let(:md_path) { File.join(tmp_dir, 'code-review-report.md') }
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 42, commit_sha: 'deadbeef',
                                         branch: 'feat', base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: 1)
    end
    let(:fake_commenter) { instance_double(Thingie::GitHub::Commenter, post_review: nil) }
    let(:overrides) { { provider: 'openai', llm_api_key: 'secret' } }
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: overrides) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::GitHub::Commenter).to receive(:new).and_return(fake_commenter)
      allow(Thingie::LlmClient).to receive(:new).and_call_original
      report.save(tmp_dir)
      File.write(md_path, 'summary')
      allow(Thingie::Env).to receive(:fetch).and_call_original
      allow(Thingie::Env).to receive(:fetch).with('GITHUB_TOKEN', nil).and_return('token')
    end

    def run_github_comment
      Thingie::CLI.start(['github-comment', '--md-report-file', md_path, '--pr', '42', '--gh-repo', 'o/r'])
    end

    def passed_filter
      filter = nil
      expect(Thingie::GitHub::Commenter).to have_received(:new) { |**args| filter = args[:duplicate_filter] }
      filter
    end

    it 'gives the commenter a repeat check by default' do
      run_github_comment

      expect(passed_filter).to be_a(Thingie::DuplicateFilter)
    end

    context 'when [dedupe] is turned off' do
      let(:overrides) { super().merge('dedupe' => { 'enabled' => false }) }

      it 'gives the commenter none' do
        run_github_comment

        expect(passed_filter).to be_nil
      end
    end

    context 'when [dedupe] names its own model' do
      let(:overrides) { super().merge('dedupe' => { 'enabled' => true, 'model' => 'cheap/model' }) }

      it 'builds the filter on that model' do
        run_github_comment

        expect(Thingie::LlmClient).to have_received(:new).with(config, model: 'cheap/model')
      end
    end

    context 'when there is no LLM key, as in the comment step of many workflows' do
      let(:overrides) { { provider: 'openai', llm_api_key: '' } }

      it 'goes without a repeat check and says nothing', :aggregate_failures do
        expect { run_github_comment }.not_to output.to_stderr
        expect(passed_filter).to be_nil
      end

      it 'says why when debugging' do
        allow(Thingie::Env).to receive(:fetch).with('THINGIE_DEBUG', nil).and_return('1')

        expect { run_github_comment }.to output(/Repeated-finding check disabled/).to_stderr
      end
    end

    context 'when building the filter fails for another reason' do
      it 'goes without a repeat check and says so', :aggregate_failures do
        allow(Thingie::LlmClient).to receive(:new).and_raise(RuntimeError, 'boom')

        expect { run_github_comment }.to output(/Repeated-finding check disabled — boom/).to_stderr
        expect(passed_filter).to be_nil
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
