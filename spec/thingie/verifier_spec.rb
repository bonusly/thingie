# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Verifier do
  subject(:verifier) do
    described_class.new(
      config: config,
      changeset: fake_changeset,
      prompt_builder: Thingie::PromptBuilder.new(Thingie::Configuration.new(root: tmp_dir)),
      llm_client: fake_llm_client
    )
  end

  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) do
    Thingie::Configuration.new(root: tmp_dir, overrides: { 'verify' => { 'enabled' => true },
                                                           'max_concurrent_tasks' => 4 })
  end
  let(:fake_changeset) do
    instance_double(Thingie::Changeset, diff_text_for: "+ x\n", full_content_for: "x\n")
  end
  let(:issues) { [issue('keep-me'), issue('reject-me')] }
  # Branch on the rendered prompt (which embeds the finding title) so the result
  # is independent of fiber scheduling order.
  let(:fake_llm_client) do
    instance_double(Thingie::LlmClient).tap do |client|
      allow(client).to receive(:complete_with_schema) do |prompt, *_|
        verdict(prompt.include?('reject-me') ? 'reject' : 'uphold')
      end
    end
  end

  def issue(title)
    Thingie::Issue.from_hash('title' => title, 'details' => 'd', 'severity' => 1,
                             'confidence' => 1, 'tags' => [], 'file' => 'app.rb',
                             'affected_lines' => [{ 'start_line' => 1 }])
  end

  def verdict(value, severity_override: nil, confidence_override: nil)
    instance_double(RubyLLM::Message, content: {
                      'verdict' => value, 'reasoning' => 'r',
                      'severity_override' => severity_override, 'confidence_override' => confidence_override
                    })
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'drops findings the critic rejects and keeps the rest' do
    kept = verifier.call(issues)
    expect(kept.map(&:title)).to eq(['keep-me'])
  end

  context 'when the critic supplies a severity/confidence override' do
    let(:issues) { [issue('override-me')] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema)
          .and_return(verdict('uphold', severity_override: 1, confidence_override: 2))
      end
    end

    it 'applies the override to the kept issue', :aggregate_failures do
      kept = verifier.call(issues)
      expect(kept.first.severity).to eq(1)
      expect(kept.first.confidence).to eq(2)
    end
  end

  context 'when the critic supplies an out-of-range override' do
    let(:issues) { [issue('override-me')] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema)
          .and_return(verdict('uphold', severity_override: 99))
      end
    end

    it 'ignores the invalid override, leaving the original grade' do
      kept = verifier.call(issues)
      expect(kept.first.severity).to eq(1)
    end
  end

  it 'returns issues untouched without calling the LLM when disabled', :aggregate_failures do
    config['verify']['enabled'] = false
    expect(verifier.call(issues)).to eq(issues)
    expect(fake_llm_client).not_to have_received(:complete_with_schema)
  end

  context 'with VERIFY_ENABLED environment variable' do
    before { Thingie::Env['VERIFY_ENABLED'] = 'false' }

    it 'disables the critic pass even when config says enabled', :aggregate_failures do
      expect(verifier.call(issues)).to eq(issues)
      expect(fake_llm_client).not_to have_received(:complete_with_schema)
    end
  end

  it 'short-circuits on an empty list' do
    expect(verifier.call([])).to eq([])
  end

  context 'when the critic call fails' do
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema).and_raise(StandardError, 'boom')
      end
    end

    it 'fails open: keeps the finding and records a warning', :aggregate_failures do
      kept = verifier.call([issue('keep-me')])
      expect(kept.map(&:title)).to eq(['keep-me'])
      expect(verifier.warnings).to include(/Could not verify finding 'keep-me'.*boom/)
    end
  end

  context 'when debug_output is provided' do
    subject(:debug_verifier) do
      described_class.new(
        config: config,
        changeset: fake_changeset,
        prompt_builder: Thingie::PromptBuilder.new(Thingie::Configuration.new(root: tmp_dir)),
        llm_client: fake_llm_client,
        debug_output: fake_debug_output
      )
    end

    let(:fake_debug_output) { instance_double(Thingie::DebugOutput) }

    before { allow(fake_debug_output).to receive(:critic_call) }

    it 'calls critic_call with the issue, response, and verdict for each finding' do
      debug_verifier.call(issues)
      expect(fake_debug_output).to have_received(:critic_call)
        .with(issue: issues[0], response: anything, verdict: 'uphold')
      expect(fake_debug_output).to have_received(:critic_call)
        .with(issue: issues[1], response: anything, verdict: 'reject')
    end

    it 'does not call critic_call when verifier is disabled' do
      config['verify']['enabled'] = false
      debug_verifier.call(issues)
      expect(fake_debug_output).not_to have_received(:critic_call)
    end
  end

  context 'when a Usage accumulator is provided' do
    subject(:usage_verifier) do
      described_class.new(
        config: config,
        changeset: fake_changeset,
        prompt_builder: Thingie::PromptBuilder.new(Thingie::Configuration.new(root: tmp_dir)),
        llm_client: token_llm_client,
        usage: usage
      )
    end

    let(:usage) { Thingie::Stats::Usage.new }
    let(:token_llm_client) do
      response = instance_double(RubyLLM::Message, content: { 'verdict' => 'uphold' },
                                                   input_tokens: 30, output_tokens: 10, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil,
                                                   cost: instance_double(RubyLLM::Cost, total: 0.0002))
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'records each critic response into the accumulator', :aggregate_failures do
      usage_verifier.call([issue('keep-me'), issue('reject-me')])
      expect(usage.input_tokens).to eq(60)
      expect(usage.output_tokens).to eq(20)
      expect(usage.cost).to be_within(1e-9).of(0.0004)
    end
  end
end
