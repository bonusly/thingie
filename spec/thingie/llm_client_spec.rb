# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'logger'

RSpec.describe Thingie::LlmClient do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:config_without_key) do
    Thingie::Configuration.new(
      root: tmp_dir,
      overrides: { 'llm_api_key' => nil, 'provider' => 'openai' }
    )
  end
  let(:config_with_key) do
    Thingie::Configuration.new(root: tmp_dir, overrides: { 'llm_api_key' => 'sk-test' })
  end

  let(:config) do
    Thingie::Configuration.new(
      root: tmp_dir,
      overrides: {
        provider: provider,
        llm_api_key: 'secret',
        llm_api_base: 'https://example.com/v1'
      }
    )
  end

  # The client builds its own RubyLLM context, so inspect that instead of the
  # global RubyLLM.config singleton.
  def context_config(client)
    client.llm_context.config
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'raises when LLM_API_KEY is missing' do
    expect { described_class.new(config_without_key) }
      .to raise_error(Thingie::ConfigurationError, /Missing LLM_API_KEY/)
  end

  it 'constructs when LLM_API_KEY is present' do
    expect { described_class.new(config_with_key) }.not_to raise_error
  end

  context 'with an unsupported provider' do
    let(:provider) { 'unknown' }

    it 'raises an argument error' do
      expect { described_class.new(config) }.to raise_error(ArgumentError, /Unsupported LLM provider/)
    end
  end

  context 'with openai' do
    let(:provider) { 'openai' }

    it 'returns an llm client' do
      expect(described_class.new(config)).to be_a(described_class)
    end

    it 'configures the openai api key' do
      expect(context_config(described_class.new(config)).openai_api_key).to eq('secret')
    end

    it 'configures the openai api base' do
      expect(context_config(described_class.new(config)).openai_api_base).to eq('https://example.com/v1')
    end
  end

  context 'with anthropic' do
    let(:provider) { 'anthropic' }

    it 'configures the anthropic api key' do
      expect(context_config(described_class.new(config)).anthropic_api_key).to eq('secret')
    end

    it 'configures the anthropic api base' do
      expect(context_config(described_class.new(config)).anthropic_api_base).to eq('https://example.com/v1')
    end
  end

  context 'when configured' do
    let(:provider) { 'openai' }

    it 'does not mutate the global RubyLLM openai_api_key' do
      before_key = RubyLLM.config.openai_api_key
      described_class.new(config)
      expect(RubyLLM.config.openai_api_key).to eq(before_key)
    end
  end

  context 'with timeout and retries from config' do
    let(:provider) { 'openai' }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: {
          provider: provider,
          llm_api_key: 'secret',
          model: 'gpt-4o-mini',
          request_timeout: 45,
          retries: 7
        }
      )
    end

    it 'applies request_timeout and retries to the context', :aggregate_failures do
      cfg = context_config(described_class.new(config))
      expect(cfg.request_timeout).to eq(45)
      expect(cfg.max_retries).to eq(7)
    end

    it 'passes the configured provider and model when starting a chat' do
      client = described_class.new(config)
      chat_double = instance_double(RubyLLM::Chat, ask: 'response')
      allow(chat_double).to receive(:with_schema).and_return(chat_double)
      allow(client.llm_context).to receive(:chat).and_return(chat_double)
      client.complete_with_schema('test prompt', {})
      expect(client.llm_context).to have_received(:chat).with(model: 'gpt-4o-mini', provider: 'openai')
    end
  end

  context 'when completing with a schema and tools' do
    let(:config) do
      Thingie::Configuration.new(root: tmp_dir, overrides: { provider: 'openai', llm_api_key: 'secret' })
    end

    it 'attaches tools before applying the schema when tools are given', :aggregate_failures do
      client = described_class.new(config)
      chat_double = instance_double(RubyLLM::Chat)
      schema_double = instance_double(RubyLLM::Chat, ask: 'response')
      tool = instance_double(RubyLLM::Tool)
      allow(client.llm_context).to receive(:chat).and_return(chat_double)
      allow(chat_double).to receive(:with_tools).with(tool).and_return(chat_double)
      allow(chat_double).to receive(:with_schema).and_return(schema_double)

      client.complete_with_schema('prompt', { type: 'object' }, tools: [tool])

      expect(chat_double).to have_received(:with_tools).with(tool)
      expect(chat_double).to have_received(:with_schema).with({ type: 'object' })
    end

    it 'records each tool call the model makes, with what it was asked, in the log it is given', :aggregate_failures do
      client = described_class.new(config)
      chat_double = instance_double(RubyLLM::Chat, with_schema: instance_double(RubyLLM::Chat, ask: 'response'))
      hook = nil
      allow(chat_double).to receive(:with_tools).and_return(chat_double)
      allow(chat_double).to receive(:before_tool_call) do |&block|
        hook = block
        chat_double
      end
      allow(client.llm_context).to receive(:chat).and_return(chat_double)
      log = []

      client.complete_with_schema('prompt', { type: 'object' }, tools: [instance_double(RubyLLM::Tool)], tool_log: log)
      asked = { pattern: 'amounts_within_max', path: nil, ignore_case: false }
      hook.call(instance_double(RubyLLM::ToolCall, name: 'thingie--search', arguments: asked))
      hook.call(instance_double(RubyLLM::ToolCall, name: 'thingie--files', arguments: {}))
      hook.call(instance_double(RubyLLM::ToolCall, name: 'thingie--search', arguments: { pattern: 'x' * 150 }))

      expect(log.first(2)).to eq(['thingie--search amounts_within_max', 'thingie--files'])
      expect(log.last).to eq("thingie--search #{'x' * 97}...")
    end

    context 'when the model cannot combine tools with a response schema' do
      let(:config) do
        Thingie::Configuration.new(root: tmp_dir, overrides: { provider: 'openai', llm_api_key: 'secret',
                                                               schema_with_tools: false })
      end
      let(:chat_double) { instance_double(RubyLLM::Chat, ask: 'response', with_tools: nil, with_schema: nil) }

      before do
        allow(chat_double).to receive_messages(with_tools: chat_double, with_schema: chat_double)
        allow(described_class.new(config).llm_context).to receive(:chat)
      end

      it 'asks without the schema when tools are given, so the model can call them', :aggregate_failures do
        client = described_class.new(config)
        allow(client.llm_context).to receive(:chat).and_return(chat_double)

        client.complete_with_schema('prompt', { type: 'object' }, tools: [instance_double(RubyLLM::Tool)])

        expect(chat_double).to have_received(:with_tools)
        expect(chat_double).not_to have_received(:with_schema)
      end

      it 'still applies the schema when there are no tools' do
        client = described_class.new(config)
        allow(client.llm_context).to receive(:chat).and_return(chat_double)

        client.complete_with_schema('prompt', { type: 'object' })

        expect(chat_double).to have_received(:with_schema).with({ type: 'object' })
      end
    end

    it 'skips with_tools when no tools are given' do
      client = described_class.new(config)
      chat_double = instance_double(RubyLLM::Chat, with_schema: instance_double(RubyLLM::Chat, ask: 'r'))
      allow(chat_double).to receive(:with_tools)
      allow(client.llm_context).to receive(:chat).and_return(chat_double)

      client.complete_with_schema('prompt', { type: 'object' })

      expect(chat_double).not_to have_received(:with_tools)
    end
  end

  context 'with log_file and log_level from config' do
    let(:provider) { 'openai' }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: {
          provider: provider,
          llm_api_key: 'secret',
          log_file: File.join(tmp_dir, 'thingie-test.log'),
          log_level: 'debug'
        }
      )
    end

    it 'applies log_file and log_level to the context', :aggregate_failures do
      cfg = context_config(described_class.new(config))
      expect(cfg.log_file).to eq(File.join(tmp_dir, 'thingie-test.log'))
      expect(cfg.log_level).to eq(Logger::DEBUG)
    end
  end

  context 'with an invalid log_level' do
    let(:provider) { 'openai' }
    let(:config) do
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: {
          provider: provider,
          llm_api_key: 'secret',
          log_level: 'verbose'
        }
      )
    end

    it 'falls back to info level' do
      expect(context_config(described_class.new(config)).log_level).to eq(Logger::INFO)
    end
  end

  context 'with a models_file pointing to an existing JSON registry' do
    def models_path
      File.join(tmp_dir, 'models.json')
    end

    def config
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: {
          'provider' => 'openai',
          'llm_api_key' => 'secret',
          'models_file' => models_path
        }
      )
    end

    # Save/restore the global RubyLLM registry the client mutates, and reset the
    # cached singleton so later specs reload from the original shipped file.
    around do |example|
      original_file = RubyLLM.config.model_registry_file
      example.run
    ensure
      RubyLLM.config.model_registry_file = original_file
      RubyLLM::Models.instance_variable_set(:@instance, nil)
    end

    before do
      File.write(models_path, <<~JSON)
        [
          {
            "id": "thingie-test-model",
            "name": "Thingie Test",
            "provider": "openai",
            "type": "chat",
            "family": "test",
            "modalities": { "input": ["text"], "output": ["text"] }
          }
        ]
      JSON
    end

    it 'points the global registry at the configured file', :aggregate_failures do
      described_class.new(config)
      expect(RubyLLM.config.model_registry_file).to eq(models_path)
      expect(RubyLLM.models.any? { |m| m.id == 'thingie-test-model' }).to be(true)
    end

    it 'can resolve a model from the local registry' do
      described_class.new(config)
      model = RubyLLM.models.find('thingie-test-model')
      expect(model.name).to eq('Thingie Test')
    end
  end

  context 'with a models_file that does not exist' do
    def config
      Thingie::Configuration.new(
        root: tmp_dir,
        overrides: {
          'provider' => 'openai',
          'llm_api_key' => 'secret',
          'models_file' => File.join(tmp_dir, 'missing.json')
        }
      )
    end

    around do |example|
      original_file = RubyLLM.config.model_registry_file
      example.run
    ensure
      RubyLLM.config.model_registry_file = original_file
      RubyLLM::Models.instance_variable_set(:@instance, nil)
    end

    it 'leaves the global registry file untouched' do
      original = RubyLLM.config.model_registry_file
      described_class.new(config)
      expect(RubyLLM.config.model_registry_file).to eq(original)
    end
  end
end
