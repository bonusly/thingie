# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe Thingie::AgentCli::Client do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:schema) { Thingie::Schemas::ISSUE_SCHEMA }
  let(:schema_json) { JSON.generate(schema[:schema]) }
  let(:provider) { 'claude-code' }
  let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { provider: provider, model: 'sonnet' }) }
  let(:stdin) { StringIO.new }
  let(:stdout_text) { '' }
  let(:stderr_text) { '' }
  let(:exit_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:argv) { [] }
  let(:schema_file_text) { [] }

  let(:claude_output) do
    [
      { type: 'system', subtype: 'init' },
      { type: 'assistant', message: { content: [
        { type: 'tool_use', name: 'Glob', input: { pattern: '*.json' } },
        { type: 'tool_use', name: 'StructuredOutput', input: { issues: [] } }
      ] } },
      { type: 'result', subtype: 'success', is_error: false, structured_output: { issues: [] },
        result: '{"issues":[]}', total_cost_usd: 0.00076263, modelUsage: { 'claude-sonnet-5' => {} },
        usage: { input_tokens: 4, output_tokens: 280, cache_read_input_tokens: 9123,
                 cache_creation_input_tokens: 2655, output_tokens_details: { thinking_tokens: 155 } } }
    ].map { |line| JSON.generate(line) }.join("\n")
  end

  let(:codex_output) do
    [
      { type: 'thread.started', thread_id: 't' },
      { type: 'item.completed', item: { id: 'item_0', type: 'command_execution', command: 'rg foo' } },
      { type: 'item.completed', item: { id: 'item_1', type: 'agent_message', text: 'thinking aloud' } },
      { type: 'item.completed', item: { id: 'item_2', type: 'agent_message', text: '{"issues":[]}' } },
      { type: 'turn.completed', usage: { input_tokens: 14_919, cached_input_tokens: 4_000, output_tokens: 19,
                                         reasoning_output_tokens: 0 } }
    ].map { |line| JSON.generate(line) }.join("\n")
  end

  before do
    allow(Open3).to receive(:popen3) do |*args, **_opts, &block|
      argv.replace(args)
      schema_path = args[args.index('--output-schema') + 1] if args.include?('--output-schema')
      schema_file_text << File.read(schema_path) if schema_path
      waiter = instance_double(Process::Waiter, value: exit_status, alive?: false, pid: 1)
      block.call(stdin, StringIO.new(stdout_text), StringIO.new(stderr_text), waiter)
    end
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def complete(**)
    described_class.new(config).complete_with_schema('review this', schema, **)
  end

  context 'with claude-code' do
    let(:stdout_text) { claude_output }

    it 'runs claude -p with the schema and read-only tools, and returns the structured output',
       :aggregate_failures do
      tool_log = []
      message = complete(tool_log: tool_log)

      expect(stdin.string).to eq('review this')
      expect(argv).to include('-p', '--safe-mode')
      expect(argv.each_cons(2)).to include(['--json-schema', schema_json], %w[--model sonnet],
                                           %w[--tools Read,Grep,Glob])
      expect(message).to be_a(RubyLLM::Message)
      expect(message.content).to eq('{"issues":[]}')
      expect(message.model).to eq('claude-sonnet-5')
      expect(message.tokens.input).to eq(4)
      expect(message.tokens.cache_read).to eq(9123)
      expect(message.cost.total).to eq(0.00076263)
      expect(tool_log).to eq(['Glob *.json'])
    end

    it 'leaves chats empty, since there is no conversation to follow up in' do
      chats = []
      complete(chats: chats)
      expect(chats).to be_empty
    end

    context 'when the result is an error' do
      let(:stdout_text) { JSON.generate(type: 'result', subtype: 'success', is_error: true, result: 'Not logged in') }
      let(:exit_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

      it 'raises the reported failure' do
        expect { complete }.to raise_error(Thingie::AgentCliError, /claude: Not logged in/)
      end
    end

    context 'when the run fails without a result' do
      let(:stdout_text) { 'not json' }
      let(:stderr_text) { 'boom' }
      let(:exit_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

      it 'raises with the exit status and stderr' do
        expect { complete }.to raise_error(Thingie::AgentCliError, /claude exited 1: boom/)
      end
    end

    it 'explains how to install and sign in when claude is missing' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)
      expect { complete }
        .to raise_error(Thingie::ConfigurationError, /claude not found on PATH.*claude auth login/)
    end
  end

  context 'with codex' do
    let(:provider) { 'codex' }
    let(:stdout_text) { codex_output }

    it 'runs codex exec in a read-only sandbox and returns the last agent message', :aggregate_failures do
      tool_log = []
      message = complete(tool_log: tool_log)

      expect(argv.first(3)).to eq(%w[codex exec -])
      expect(argv.each_cons(2)).to include(%w[-m sonnet], %w[--sandbox read-only], ['-C', tmp_dir])
      expect(schema_file_text).to eq([schema_json])
      expect(message.content).to eq('{"issues":[]}')
      expect(message.tokens.output).to eq(19)
      expect(message.tokens.input).to eq(10_919)
      expect(message.tokens.cache_read).to eq(4_000)
      expect(message.cost.total).to be_nil
      expect(tool_log).to eq(['command rg foo'])
    end

    context 'when the model comes from the project config file' do
      let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { provider: provider }) }

      before do
        FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
        File.write(File.join(tmp_dir, '.thingie', 'config.toml'), "model = \"openai/gpt-6-sol\"\n")
      end

      it "runs on Codex's default model instead of the project's API model" do
        complete
        expect(argv).not_to include('-m')
      end

      it 'passes LLM_MODEL when it is set' do
        Thingie::Env['LLM_MODEL'] = 'gpt-6-luna'
        complete
        expect(argv.each_cons(2)).to include(%w[-m gpt-6-luna])
      end

      it 'still passes a dedicated model, such as the critic model' do
        described_class.new(config, model: 'gpt-6-luna').complete_with_schema('x', schema)
        expect(argv.each_cons(2)).to include(%w[-m gpt-6-luna])
      end
    end

    context 'when the turn fails' do
      let(:stdout_text) { JSON.generate(type: 'turn.failed', error: { message: 'model not supported' }) }

      it 'raises the reported failure' do
        expect { complete }.to raise_error(Thingie::AgentCliError, /codex: model not supported/)
      end
    end
  end
end
