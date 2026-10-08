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
    instance_double(Thingie::Changeset, diff_text_for: "+ x\n", full_content_for: "x\n", all?: false,
                                        patches: [])
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
    message_double(
                    content: {
                      'verdict' => value, 'reasoning' => 'r',
                      'severity_override' => severity_override,
                      'confidence_override' => confidence_override
                    },
                    thinking: nil, thinking_tokens: nil,
                    input_tokens: nil, output_tokens: nil, tool_calls: {},
                    cache_read_tokens: nil, cache_write_tokens: nil,
                    cost: instance_double(RubyLLM::Cost, total: nil), model_info: nil)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'drops findings the critic rejects and keeps the rest' do
    kept = verifier.call(issues)
    expect(kept.map(&:title)).to eq(['keep-me'])
  end

  context 'when the critic uses its tools' do
    let(:issues) { [issue('keep-me')] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |_prompt, _schema, tool_log: nil, **|
          tool_log&.push('thingie--search amounts_within_max', 'thingie--file app/models/award.rb')
          verdict('uphold')
        end
      end
    end

    it 'keeps what it asked the tools on the finding' do
      expect(verifier.call(issues).first.critic_tool_calls)
        .to eq(['thingie--search amounts_within_max', 'thingie--file app/models/award.rb'])
    end
  end

  context 'when the critic replies with text and no JSON' do
    let(:issues) { [issue('keep-me')] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema).and_return(
          message_double(content: 'I could not find a problem with this.', thinking: nil, thinking_tokens: nil,
                         input_tokens: nil, output_tokens: nil, tool_calls: {}, cache_read_tokens: nil,
                         cache_write_tokens: nil, cost: instance_double(RubyLLM::Cost, total: nil), model_info: nil)
        )
      end
    end

    it 'keeps the finding and says the critic did not run', :aggregate_failures do
      expect(verifier.call(issues)).to eq(issues)
      expect(verifier.warnings).to include(/Could not verify finding 'keep-me'.*no JSON/)
    end
  end

  context 'when deciding whether to tell the critic about the symbol lookup tool' do
    let(:prompts) { [] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) { |prompt, *_| (prompts << prompt) && verdict('uphold') }
      end
    end
    let(:file_tool) { Thingie::FileTool.new(root: tmp_dir) }
    let(:symbol_tool) { Thingie::Lsp::SymbolTool.new(client: instance_double(Thingie::Lsp::Client), root: tmp_dir) }

    def critic_prompt_with(tools)
      described_class.new(config: config, changeset: fake_changeset, llm_client: fake_llm_client, tools: tools,
                          prompt_builder: Thingie::PromptBuilder.new(Thingie::Configuration.new(root: tmp_dir)))
                     .call([issue('keep-me')])
      prompts.last
    end

    it 'does not mention it when the only tools read files', :aggregate_failures do
      prompt = critic_prompt_with([file_tool])

      expect(prompt).not_to include('"No definition found" result')
    end

    it 'mentions it when the symbol tool is there', :aggregate_failures do
      expect(critic_prompt_with([file_tool, symbol_tool])).to include('"No definition found" result')
    end
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

  context 'when the critic replies with prose around the JSON, as a tool-using call without a schema does' do
    let(:issues) { [issue('reject-me')] }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema).and_return(
          message_double(content: "I checked the callers.\n{\"verdict\": \"reject\", \"reasoning\": \"guarded\"}",
                         thinking: nil, thinking_tokens: nil, input_tokens: nil, output_tokens: nil,
                         tool_calls: {}, cache_read_tokens: nil, cache_write_tokens: nil,
                         cost: instance_double(RubyLLM::Cost, total: nil), model_info: nil)
        )
      end
    end

    it 'still honours the verdict' do
      expect(verifier.call(issues)).to be_empty
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

    it 'calls critic_call with the issue, response, verdict, and content for each finding' do
      debug_verifier.call(issues)
      expect(fake_debug_output).to have_received(:critic_call)
        .with(issue: issues[0], response: anything, verdict: 'uphold',
              content: hash_including('verdict' => 'uphold'), tool_names: [])
      expect(fake_debug_output).to have_received(:critic_call)
        .with(issue: issues[1], response: anything, verdict: 'reject',
              content: hash_including('verdict' => 'reject'), tool_names: [])
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
      response = message_double(content: { 'verdict' => 'uphold' },
                                input_tokens: 30, output_tokens: 10, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil,
                                cost: instance_double(RubyLLM::Cost, total: 0.0002),
                                thinking: nil, thinking_tokens: nil)
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
