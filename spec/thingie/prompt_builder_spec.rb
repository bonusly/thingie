# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::PromptBuilder do
  subject(:builder) { described_class.new(config) }

  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) { Thingie::Configuration.new(root: tmp_dir) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe '#review' do
    it 'includes the diff input' do
      prompt = builder.review(diff: "class Foo\nend")
      expect(prompt).to include('class Foo')
    end

    it 'shows the PR-wide changes only when there are some', :aggregate_failures do
      expect(builder.review(diff: 'x', pr_context: "Files this PR touches:\n- added a.rb"))
        .to include('----OTHER CHANGES IN THIS PR----', '- added a.rb')
      expect(builder.review(diff: 'x')).not_to include('OTHER CHANGES IN THIS PR')
    end

    it 'includes prompt_vars requirements' do
      prompt = builder.review(diff: '')
      expect(prompt).to include('Lack of DRY principle enforcement')
    end

    it 'includes the JSON response requirement' do
      prompt = builder.review(diff: '')
      expect(prompt).to include('RESPOND ONLY WITH VALID JSON')
    end

    it 'adds symbol-lookup guidance only when a lookup tool is available', :aggregate_failures do
      expect(builder.review(diff: '')).not_to include('symbol lookup tool')
      expect(builder.review(diff: '', symbol_lookup: true)).to include('symbol lookup tool')
    end

    it 'inverts the diff-only guideline for whole-file reviews', :aggregate_failures do
      diff_prompt = builder.review(diff: "+ def hello\n", file_lines: "def hello\nend\n")
      expect(diff_prompt).to include('Only report issues on lines added or modified in the diff above')
      expect(diff_prompt).not_to include('report issues anywhere in it')

      whole_prompt = builder.review(diff: "def hello\nend\n", whole_file: true)
      expect(whole_prompt).to include('Every line of the file above is under review')
      expect(whole_prompt).not_to include('Only report issues on lines added or modified')
    end

    context 'when prompt_vars omits requirements/json_requirements/self_id' do
      let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { prompt_vars: {} }) }

      it 'renders without raising' do
        expect { builder.review(diff: '') }.not_to raise_error
      end
    end

    context 'with skill fragments' do
      before do
        FileUtils.mkdir_p(File.join(tmp_dir, '.cursor'))
        File.write(File.join(tmp_dir, '.cursor', 'rails.md'), 'Always use strong params.')
      end

      it 'does not inline skill content into the prompt' do
        # Skills are exposed to the LLM via SkillCatalog's progressive-disclosure
        # tool instead — inlining them here is what blew up the context window.
        prompt = builder.review(diff: '')
        expect(prompt).not_to include('Always use strong params.')
      end
    end

    it 'includes the severity rubric' do
      prompt = builder.review(diff: '')
      expect(prompt).to include('Grade severity by real-world consequence')
    end

    it 'states the show-line threshold in terms of the default post_process config' do
      prompt = builder.review(diff: '')
      expect(prompt).to include('severity 4 (Low) or better')
      expect(prompt).to include('confidence 1 (Highest, 100% confidence) or better')
    end

    it 'states that auto-approval is disabled by default' do
      prompt = builder.review(diff: '')
      expect(prompt).to include('Auto-approval is not enabled for this project')
    end

    context 'when approve is enabled' do
      let(:config) do
        Thingie::Configuration.new(root: tmp_dir, overrides: { approve: { 'enabled' => true, 'max_severity' => 2 } })
      end

      it 'states the block-line threshold' do
        prompt = builder.review(diff: '')
        expect(prompt).to include('severity 2 (High) or better also block')
      end
    end

    context 'with custom severity and confidence scales' do
      let(:config) do
        Thingie::Configuration.new(
          root: tmp_dir,
          overrides: {
            severity_scale: { '1' => 'Blocker', '2' => 'Needs Fix' },
            confidence_scale: { '1' => 'Sure', '2' => 'Guess' }
          }
        )
      end

      it 'renders the custom scales in the prompt', :aggregate_failures do
        prompt = builder.review(diff: '')
        expect(prompt).to include('- 1 — Blocker')
        expect(prompt).to include('- 2 — Needs Fix')
        expect(prompt).to include('- 1 — Sure')
        expect(prompt).to include('- 2 — Guess')
        # The default severity label must not render in the scale list (it can
        # still appear elsewhere, e.g. the requirements headings).
        expect(prompt).not_to include('- 1 — Critical')
      end
    end
  end

  describe '#review prompt style' do
    def prompt_for(config, symbol_lookup: false)
      described_class.new(config).review(diff: '+x', file_lines: 'x', symbol_lookup: symbol_lookup)
    end

    let(:verified_config) do
      Thingie::Configuration.new(root: tmp_dir, overrides: { 'review' => { 'prompt' => 'verified' } })
    end

    it 'uses the strict prompt unless told otherwise', :aggregate_failures do
      prompt = prompt_for(config)
      expect(prompt).to include('100% confident')
      expect(prompt).not_to include('VERIFY BEFORE YOU REPORT')
    end

    it 'asks the verified prompt to check suspicions with the tools and cite evidence', :aggregate_failures do
      prompt = prompt_for(verified_config)
      expect(prompt).to include('VERIFY BEFORE YOU REPORT', '"evidence"', 'search tool')
      expect(prompt).not_to include('100% confident')
      expect(prompt).to include('- 1 — Highest, 100% confidence')
    end

    it 'mentions the symbol lookup tool only when it is available', :aggregate_failures do
      expect(prompt_for(verified_config, symbol_lookup: true)).to include('symbol lookup tool')
      expect(prompt_for(verified_config, symbol_lookup: false)).not_to include('symbol lookup tool')
    end

    it 'rejects an unknown prompt style' do
      bad = Thingie::Configuration.new(root: tmp_dir, overrides: { 'review' => { 'prompt' => 'loose' } })
      expect { prompt_for(bad) }.to raise_error(ArgumentError, /Unknown \[review\] prompt "loose"/)
    end
  end

  describe '#verify' do
    let(:issue) do
      Thingie::Issue.from_hash('title' => 'Leaky query', 'details' => 'd', 'severity' => 1,
                               'confidence' => 2, 'tags' => [], 'file' => 'app.rb',
                               'affected_lines' => [{ 'start_line' => 1 }])
    end

    it 'asks whether it is true and would matter to a user when the bar is user_impact', :aggregate_failures do
      impact = Thingie::Configuration.new(root: tmp_dir, overrides: { 'verify' => { 'bar' => 'user_impact' } })
      prompt = described_class.new(impact).verify(issue: issue, diff: 'x')
      expect(prompt).to include('Would it matter to someone using the product?', 'search and file tools')
      expect(prompt).not_to include('materially valuable to a maintainer')
    end

    it 'tells the critic to always grade confidence by how far its check got when the cap comes after it',
       :aggregate_failures do
      graded = Thingie::Configuration.new(
        root: tmp_dir, overrides: { 'post_process' => { 'confidence_after_verify' => true } }
      )
      prompt = described_class.new(graded).verify(issue: issue, diff: 'x')
      expect(prompt).to include('Always give a confidence grade', '"confidence_override": <1-4>,')
      expect(builder.verify(issue: issue, diff: 'x')).not_to include('Always give a confidence grade')
    end

    it 'keeps the default bar unless told otherwise', :aggregate_failures do
      prompt = builder.verify(issue: issue, diff: 'x')
      expect(prompt).to include('materially valuable to a maintainer')
      expect(prompt).not_to include('Would it matter to someone using the product?')
    end

    it 'shows the critic the evidence the reviewer gave', :aggregate_failures do
      with_evidence = Thingie::Issue.from_hash('title' => 'Leaky query', 'details' => 'd', 'severity' => 1,
                                               'confidence' => 2, 'tags' => [], 'file' => 'app.rb',
                                               'evidence' => 'award.rb:31 skips the check',
                                               'affected_lines' => [{ 'start_line' => 1 }])
      expect(builder.verify(issue: with_evidence, diff: 'x'))
        .to include('Evidence the reviewer gave: award.rb:31 skips')
      expect(builder.verify(issue: issue, diff: 'x')).not_to include('Evidence the reviewer gave')
    end

    it 'shows the PR-wide changes only when there are some', :aggregate_failures do
      expect(builder.verify(issue: issue, diff: 'x', pr_context: "Files this PR touches:\n- added a.rb"))
        .to include('----OTHER CHANGES IN THIS PR----', '- added a.rb')
      expect(builder.verify(issue: issue, diff: 'x')).not_to include('OTHER CHANGES IN THIS PR')
    end

    it 'includes the finding\'s current severity and confidence', :aggregate_failures do
      prompt = builder.verify(issue: issue, diff: '')
      expect(prompt).to include('Severity: 1 (Critical)')
      expect(prompt).to include('Confidence: 2 (Very High)')
    end

    it 'includes the severity/confidence scales and threshold text' do
      prompt = builder.verify(issue: issue, diff: '')
      expect(prompt).to include('- 1 — Critical')
      expect(prompt).to include('severity 4 (Low) or better')
    end

    it 'includes the severity rubric' do
      prompt = builder.verify(issue: issue, diff: '')
      expect(prompt).to include('Grade severity by real-world consequence')
    end

    it 'includes the severity_override/confidence_override response fields' do
      prompt = builder.verify(issue: issue, diff: '')
      expect(prompt).to include('severity_override')
      expect(prompt).to include('confidence_override')
    end
  end
end
