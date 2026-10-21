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
      allow(RubyLLM.models).to receive(:refresh)
    end

    it 'exits with a usage message and does not call refresh' do
      expect do
        run_models([])
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(RubyLLM.models).not_to have_received(:refresh)
    end
  end

  context 'when --path is given' do
    let(:models_path) { File.join(tmp_dir, 'nested', 'models.json') }
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'models_file' => models_path }) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(RubyLLM.models).to receive(:refresh)
      allow(RubyLLM.models).to receive(:save_to_json)
      allow(RubyLLM.models).to receive(:count).and_return(7)
    end

    it 'refreshes the registry and saves it to the configured path' do
      expect do
        run_models(['--path', models_path])
      end.to output(/Saved 7 models to #{Regexp.escape(models_path)}/).to_stdout

      expect(RubyLLM.models).to have_received(:refresh).with(no_args)
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

    context 'when there is no LLM key in the comment step' do
      let(:overrides) { { provider: 'openai', llm_api_key: '' } }

      it 'goes without either LLM check and says so', :aggregate_failures do
        expect { run_github_comment }
          .to output(/Repeated-finding check disabled.*LLM_API_KEY.*Fixed-finding check disabled.*LLM_API_KEY/m)
          .to_stderr
        expect(passed_filter).to be_nil
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

  context 'when running a review with System One enabled' do
    let(:rules) do
      [{ 'threshold' => 0.5, 'label' => 'risk: needs review', 'title' => 'Needs review',
         'description' => 'A person should read this.' }]
    end
    let(:config) do
      Thingie::Configuration.new(root: tmp_dir, overrides: { 'system_one_enabled' => true, 'escalations' => rules })
    end
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: 'deadbeef',
                                         branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: 1)
    end
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, files: ['a.rb'], workdir: tmp_dir, base_ref: 'main', head_ref: 'HEAD')
    end
    let(:result) do
      file_risk = Thingie::ChangeRiskScorer::FileRisk.new(scores: { security: 0.1, overall: 0.7 }, rating: 'risky')
      Thingie::ChangeRiskScorer::Result.new(files: { 'a.rb' => file_risk }, max: { security: 0.1, overall: 0.7 },
                                            rating: 'risky', obfuscation: [])
    end
    let(:empty_result) { Thingie::ChangeRiskScorer::Result.new(files: {}, max: {}, rating: nil, obfuscation: []) }
    let(:scorer) { instance_double(Thingie::ChangeRiskScorer, call: result) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::Changeset).to receive(:new).and_return(fake_changeset)
      allow(Thingie::Reviewer).to receive(:new)
        .and_return(instance_double(Thingie::Reviewer, review: report, usage: Thingie::Stats::Usage.new))
      allow(Thingie::LlmClient).to receive(:new)
      allow(Thingie::SkillCatalog).to receive(:tool).and_return(nil)
      allow(Thingie::SystemOneClassifier).to receive(:new)
      allow(Thingie::ChangeRiskScorer).to receive(:new).and_return(scorer)
    end

    def run_review
      Thingie::CLI.start(['review', '--output', tmp_dir])
    end

    it 'records the scores and the escalation labels on the report' do
      run_review

      expect(report.change_risk).to eq('model' => 'jev-latest', 'max' => { 'security' => 0.1, 'overall' => 0.7 },
                                       'rating' => 'risky',
                                       'files' => { 'a.rb' => { 'scores' => { 'security' => 0.1, 'overall' => 0.7 },
                                                                'rating' => 'risky' } },
                                       'escalations' => [{ 'label' => 'risk: needs review', 'title' => 'Needs review',
                                                           'description' => 'A person should read this.' }],
                                       'rules' => rules)
    end

    it 'scores before the review and hands the ratings to the reviewer', :aggregate_failures do
      run_review

      expect(Thingie::Reviewer).to have_received(:new).with(hash_including(file_ratings: { 'a.rb' => 'risky' }))
      expect(report.change_risk['rating']).to eq('risky')
    end

    it 'records an empty change risk when no file was scored, so stale labels are cleared' do
      allow(scorer).to receive(:call).and_return(empty_result)

      run_review

      expect(report.change_risk).to eq('model' => 'jev-latest', 'max' => {}, 'rating' => nil, 'files' => {},
                                       'escalations' => [],
                                       'rules' => rules)
    end

    context 'with a threshold-zero rule and nothing scored' do
      let(:rules) { [{ 'threshold' => 0, 'label' => 'risk: any' }] }

      it 'matches no rule on the absent score' do
        allow(scorer).to receive(:call).and_return(empty_result)

        run_review

        expect(report.change_risk['escalations']).to eq([])
      end
    end

    context 'with a malformed escalation rule' do
      let(:rules) { [{ 'threshold' => 0.5, 'label' => ' ' }] }

      it 'fails the review before the LLM review starts', :aggregate_failures do
        expect { expect { run_review }.to raise_error(SystemExit) }
          .to output(/Review failed: Thingie::ConfigurationError: escalations label/).to_stderr
        expect(Thingie::Reviewer).not_to have_received(:new)
      end
    end

    context 'with malformed change-risk ratings' do
      before { config.dig('change_risk', 'ratings', 'critical')['floor'] = 0.4 }

      it 'fails the review before the LLM review starts', :aggregate_failures do
        expect { expect { run_review }.to raise_error(SystemExit) }
          .to output(/Review failed: Thingie::ConfigurationError: change_risk\.ratings floors must rise/).to_stderr
        expect(Thingie::Reviewer).not_to have_received(:new)
      end
    end

    it 'keeps the review when scoring fails', :aggregate_failures do
      allow(scorer).to receive(:call).and_raise(Thingie::SystemOneError, 'boom')

      expect { run_review }.to output(/Change risk scoring skipped: boom.*existing labels left unchanged/).to_stderr
      expect(report.change_risk).to be_nil
      expect(report.processing_warnings).to include(/boom/)
      expect(Thingie::Reviewer).to have_received(:new).with(hash_including(file_ratings: {}))
    end

    it 'keeps the review when scoring raises an error that is not a System One error', :aggregate_failures do
      allow(scorer).to receive(:call).and_raise(OpenSSL::SSL::SSLError, 'handshake failed')

      expect { run_review }.to output(/Change risk scoring skipped: handshake failed/).to_stderr
      expect(report.change_risk).to be_nil
    end

    it 'keeps the review when System One is misconfigured', :aggregate_failures do
      allow(Thingie::SystemOneClassifier).to receive(:new)
        .and_raise(Thingie::ConfigurationError, 'Missing SYSTEM_ONE_API_KEY.')

      expect { run_review }.to output(/Change risk scoring skipped: Missing SYSTEM_ONE_API_KEY/).to_stderr
      expect(report.change_risk).to be_nil
      expect(report.processing_warnings).to include(/Missing SYSTEM_ONE_API_KEY/)
    end

    context 'when System One is disabled but escalations are configured' do
      let(:config) do
        Thingie::Configuration.new(root: tmp_dir, overrides: { 'system_one_enabled' => false, 'escalations' => rules })
      end

      it 'warns, skips scoring and leaves the report without a change risk', :aggregate_failures do
        expect { run_review }.to output(/escalations are configured but System One is disabled.*left unchanged/)
          .to_stderr
        expect(scorer).not_to have_received(:call)
        expect(report.change_risk).to be_nil
        expect(Thingie::Reviewer).to have_received(:new).with(hash_including(file_ratings: {}))
      end
    end
  end

  context 'when running risk' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'system_one_enabled' => true }) }
    let(:result) do
      file_risk = Thingie::ChangeRiskScorer::FileRisk.new(scores: { security: 0.1, overall: 0.7 }, rating: 'risky')
      Thingie::ChangeRiskScorer::Result.new(files: { 'a.rb' => file_risk }, max: { security: 0.1, overall: 0.7 },
                                            rating: 'risky', obfuscation: [])
    end
    let(:scorer) { instance_double(Thingie::ChangeRiskScorer, call: result) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::Changeset).to receive(:new).and_return(instance_double(Thingie::Changeset))
      allow(Thingie::SystemOneClassifier).to receive(:new)
      allow(Thingie::ChangeRiskScorer).to receive(:new).and_return(scorer)
    end

    it "prints each file's rating and scores" do
      expect { described_class.start(['risk']) }.to output(/^  - a\.rb: risky \(review need 0\.70; security 0\.10\)$/)
        .to_stdout
    end

    it 'exits 1 when scoring fails' do
      allow(scorer).to receive(:call).and_raise(Thingie::SystemOneError, 'boom')

      expect { expect { described_class.start(['risk']) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) } }
        .to output(/Risk scoring failed: Thingie::SystemOneError: boom/).to_stderr
    end

    context 'with System One disabled, its default' do
      let(:config) { Thingie::Configuration.new(root: tmp_dir) }

      it 'refuses to score' do
        allow(Thingie::SystemOneClassifier).to receive(:new).and_call_original

        expect { expect { described_class.start(['risk']) }.to raise_error(SystemExit) }
          .to output(/Risk scoring failed: Thingie::ConfigurationError: System One is disabled/).to_stderr
      end
    end
  end

  context 'when running github-comment on a report with a change risk' do
    let(:rules) { [{ 'threshold' => 0.5, 'label' => 'risk: needs review' }] }
    let(:config) { Thingie::Configuration.new(root: tmp_dir) }
    let(:md_path) { File.join(tmp_dir, 'code-review-report.md') }
    let(:report) do
      target = Thingie::ReviewTarget.new(platform: 'github', repo_url: nil, pr_number: 42, commit_sha: 'deadbeef',
                                         branch: 'feat', base_ref: 'main', head_ref: 'HEAD', merge_base: false)
      Thingie::Report.new(target: target, model: 'm', issues: [], number_of_processed_files: 1).tap do |built|
        built.change_risk = { 'max' => { 'overall' => 0.7 }, 'files' => {}, 'rules' => rules,
                              'escalations' => [{ 'label' => 'risk: needs review' }] }
      end
    end
    let(:fake_commenter) { instance_double(Thingie::GitHub::Commenter, post_review: nil) }
    let(:escalator) { instance_double(Thingie::GitHub::Escalator, call: ['risk: needs review']) }

    before do
      allow(Thingie::Configuration).to receive(:new).and_return(config)
      allow(Thingie::GitHub::Commenter).to receive(:new).and_return(fake_commenter)
      allow(Thingie::GitHub::Escalator).to receive(:new).and_return(escalator)
      report.save(tmp_dir)
      File.write(md_path, 'summary')
    end

    def run_github_comment
      Thingie::CLI.start(['github-comment', '--md-report-file', md_path, '--pr', '42', '--gh-repo', 'o/r'])
    end

    it 'labels the PR for the report overall score' do
      run_github_comment

      expect(escalator).to have_received(:call).with(0.7)
    end

    it 'clears stale labels when the report scored nothing' do
      report.change_risk = { 'max' => {}, 'files' => {}, 'rules' => rules, 'escalations' => [] }
      report.save(tmp_dir)

      run_github_comment

      expect(escalator).to have_received(:call).with(nil)
    end

    it 'builds the rules from the report, not the current config', :aggregate_failures do
      run_github_comment

      expect(Thingie::GitHub::Escalator).to have_received(:new)
        .with(hash_including(rules: an_object_having_attributes(managed_labels: ['risk: needs review'])))
    end

    it 'still posts the review when labelling fails', :aggregate_failures do
      allow(escalator).to receive(:call).and_raise(StandardError, 'no permission')

      expect { run_github_comment }.to output(/Escalation failed: StandardError: no permission/).to_stderr
      expect(fake_commenter).to have_received(:post_review)
    end

    it 'does not touch labels when the report has no change risk' do
      report.change_risk = nil
      report.save(tmp_dir)

      run_github_comment

      expect(Thingie::GitHub::Escalator).not_to have_received(:new)
    end
  end
end
