# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::ClaudeCodeSource do
  subject(:source) do
    described_class.new(config: config, changeset: changeset, prompt_builder: Thingie::PromptBuilder.new(config),
                        usage: usage, runner: runner)
  end

  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) { Thingie::Configuration.new(root: tmp_dir) }
  let(:usage) { Thingie::Stats::Usage.new }
  let(:changeset) do
    instance_double(Thingie::Changeset, files: ['app.rb', 'lib/b.rb'], base_ref: 'main', head_ref: 'HEAD',
                                        workdir: tmp_dir, patch_text: "diff --git a/app.rb b/app.rb\n+def hello\n")
  end
  let(:status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:findings) do
    [{ 'file' => 'app.rb', 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
       'confidence' => 1, 'tags' => ['bug'],
       'affected_lines' => [{ 'start_line' => 1, 'end_line' => nil, 'proposal' => nil }] },
     { 'file' => 'lib/b.rb', 'title' => 'N+1', 'details' => 'Loads per row', 'severity' => 3,
       'confidence' => 1, 'tags' => ['performance'],
       'affected_lines' => [{ 'start_line' => 4, 'end_line' => 6, 'proposal' => nil }] }]
  end
  let(:cli_result) do
    { 'result' => 'Two findings survived verification.', 'total_cost_usd' => 0.42, 'num_turns' => 17,
      'duration_ms' => 90_000, 'session_id' => 'sess-1',
      'usage' => { 'input_tokens' => 1000, 'output_tokens' => 200, 'cache_read_input_tokens' => 50,
                   'cache_creation_input_tokens' => 10 },
      'modelUsage' => { 'claude-haiku-4-5' => { 'costUSD' => 0.02 }, 'claude-sonnet-5-5' => { 'costUSD' => 0.4 } },
      'structured_output' => { 'issues' => findings } }
  end
  let(:stdout) { JSON.generate(cli_result) }
  let(:calls) { [] }
  let(:runner) do
    lambda do |argv, chdir:, stdin:, timeout:|
      calls << { argv: argv, chdir: chdir, stdin: stdin, timeout: timeout }
      [stdout, '', status]
    end
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'parses the structured findings per file', :aggregate_failures do
    issues = source.call
    expect(issues.map(&:file)).to eq(['app.rb', 'lib/b.rb'])
    expect(issues.first.title).to eq('Missing return')
    expect(issues.last.affected_lines.first.end_line).to eq(6)
    expect(issues.map(&:id)).to all(be_nil)
    expect(source.warnings).to be_empty
  end

  it 'runs the CLI headless in the repo with the skill, schema, budget and tool lists', :aggregate_failures do
    source.call
    call = calls.first
    expect(call[:chdir]).to eq(tmp_dir)
    expect(call[:timeout]).to eq(1800)
    expect(call[:argv].first(5)).to eq(['claude', '-p', '--output-format', 'stream-json', '--verbose'])
    expect(call[:argv]).to include('--json-schema', '--max-budget-usd', '5.0', '--permission-mode', 'dontAsk')
    schema = JSON.parse(call[:argv][call[:argv].index('--json-schema') + 1])
    expect(schema.dig('properties', 'issues', 'items', 'required')).to include('file', 'severity', 'affected_lines')
    expect(call[:argv][call[:argv].index('--allowedTools') + 1])
      .to eq(config['claude_code']['allowed_tools'].join(','))
    expect(call[:argv]).not_to include('--disallowedTools')
    expect(call[:stdin]).to start_with('/code-review')
    expect(call[:stdin]).to include('`main`', '- app.rb', '- lib/b.rb', '1 — Critical')
  end

  it 'hands the run the diff as a file and points the prompt at it', :aggregate_failures do
    source.call
    expect(File.read(File.join(tmp_dir, 'log/thingie-changeset.diff'))).to start_with('diff --git a/app.rb')
    expect(calls.first[:stdin]).to include('is in `log/thingie-changeset.diff`')
  end

  it 'records the run cost and tokens into the shared usage', :aggregate_failures do
    source.call
    expect(usage.cost).to eq(0.42)
    expect(source.details['cost_source']).to eq('cli')
    expect(usage.input_tokens).to eq(1000)
    expect(usage.output_tokens).to eq(200)
    expect(usage.cache_read_tokens).to eq(50)
    expect(usage.cache_write_tokens).to eq(10)
  end

  context 'when the ruby_llm registry prices the model' do
    let(:tier) do
      instance_double(RubyLLM::Model::PricingTier, input_per_million: 1.4, output_per_million: 4.4,
                                                   cache_read_input_per_million: 0.26,
                                                   cache_write_input_per_million: nil)
    end

    before do
      info = instance_double(RubyLLM::Model::Info,
                             pricing: instance_double(RubyLLM::Model::Pricing,
                                                      text_tokens: instance_double(RubyLLM::Model::PricingCategory,
                                                                                   standard: tier)))
      allow(RubyLLM.models).to receive(:find).with('claude-sonnet-5-5', 'openai').and_return(info)
    end

    it 'prices the run from its tokens instead of trusting the CLI', :aggregate_failures do
      source.call
      # 1000 in × 1.4 + 50 cache read × 0.26 + 10 cache write × 1.4 (no cache-write rate) + 200 out × 4.4, per million
      expect(usage.cost).to be_within(1e-9).of(0.002307)
      expect(source.details).to include('cost_usd' => 0.002307, 'cost_source' => 'registry')
    end
  end

  context 'without structured output (a model the CLI cannot validate)' do
    let(:cli_result) do
      reply = "Here are the findings:\n#{JSON.generate('issues' => findings)}"
      super().except('structured_output').merge('result' => reply)
    end

    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), <<~TOML)
        [claude_code]
        model = "z-ai/glm-5.3"
        structured_output = false
        max_budget_usd = 0
        max_turns = 60
      TOML
    end

    it 'asks for the JSON in the prompt, caps turns instead of budget, and parses the reply', :aggregate_failures do
      expect(source.call.size).to eq(2)
      argv = calls.first[:argv]
      expect(argv).not_to include('--json-schema', '--max-budget-usd')
      expect(argv).to include('--max-turns', '60', '--model', 'z-ai/glm-5.3')
      expect(calls.first[:stdin])
        .to include('Your final reply must be only this JSON object', '"file": "<repo-relative path>"')
    end

    context 'when the reply has no JSON' do
      let(:cli_result) { super().merge('result' => 'I reviewed the code and found nothing worth reporting.') }

      it 'fails rather than reporting a clean review' do
        expect { source.call }.to raise_error(RuntimeError, /no findings JSON/)
      end
    end
  end

  it 'exposes the run details, naming the model that spent the most', :aggregate_failures do
    source.call
    expect(source.model).to eq('claude-sonnet-5-5')
    expect(source.details).to include('source' => 'claude_code', 'skill' => '/code-review', 'turns' => 17,
                                      'cost_usd' => 0.42, 'session_id' => 'sess-1',
                                      'notes' => 'Two findings survived verification.')
  end

  it 'saves the raw CLI result where configured' do
    source.call
    saved = JSON.parse(File.read(File.join(tmp_dir, 'log/thingie-claude-code.json')))
    expect(saved['session_id']).to eq('sess-1')
  end

  context 'when the CLI streams the transcript' do
    let(:stdout) do
      tool = lambda do |name|
        { 'type' => 'assistant', 'message' => { 'content' => [{ 'type' => 'tool_use', 'name' => name }] } }
      end
      events = [{ 'type' => 'system', 'subtype' => 'init' }, tool['Read'], tool['Task'], tool['Read'],
                cli_result.merge('type' => 'result', 'subagent_stats' => { 'spawned' => 7 })]
      events.map { |event| JSON.generate(event) }.join("\n")
    end

    it 'takes the result from the final event and counts the tool calls', :aggregate_failures do
      expect(source.call.size).to eq(2)
      expect(source.details).to include('subagents' => 7, 'tool_calls' => 'Read ×2, Task ×1', 'turns' => 17)
    end
  end

  context 'when the findings arrive only as a StructuredOutput tool call' do
    let(:stdout) do
      call = { 'type' => 'assistant',
               'message' => { 'content' => [{ 'type' => 'tool_use', 'name' => 'StructuredOutput',
                                              'input' => { 'issues' => findings } }] } }
      result = cli_result.except('structured_output').merge('type' => 'result', 'result' => 'Command completed')
      [call, result].map { |event| JSON.generate(event) }.join("\n")
    end

    it 'takes them from the tool call' do
      expect(source.call.map(&:title)).to eq(['Missing return', 'N+1'])
    end
  end

  context 'when the result names no model' do
    let(:cli_result) { super().except('modelUsage') }

    it 'falls back to the source name' do
      source.call
      expect(source.model).to eq('claude_code')
    end
  end

  context 'when findings name paths outside the changeset or lack required fields' do
    let(:findings) do
      [super().first,
       super().first.merge('file' => './app.rb', 'title' => 'Dot-slash path'),
       super().first.merge('file' => 'config/locales/en.yml', 'title' => 'Excluded file'),
       super().first.except('severity')]
    end

    it 'keeps the good ones and warns about the rest instead of failing the run', :aggregate_failures do
      issues = source.call
      expect(issues.map(&:title)).to eq(['Missing return', 'Dot-slash path'])
      expect(source.warnings).to contain_exactly(
        a_string_including('1 finding(s) for `config/locales/en.yml`, not in the changeset'),
        a_string_including('malformed Claude Code finding for app.rb')
      )
    end
  end

  context 'when the project leaves the model at its TOML default' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), "[claude_code]\nmodel = \"\"\n")
    end

    it 'lets the CLI pick, rather than passing an empty flag' do
      source.call
      expect(calls.first[:argv]).not_to include('--model')
    end
  end

  context 'when the project overrides the settings' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), <<~TOML)
        [claude_code]
        skill = "/deep-review"
        model = "claude-opus-5-5"
        disallowed_tools = ["Read(./.git/**)"]
        raw_output_file = ""
      TOML
    end

    it 'passes them to the CLI', :aggregate_failures do
      source.call
      argv = calls.first[:argv]
      expect(argv).to include('--model', 'claude-opus-5-5', '--disallowedTools', 'Read(./.git/**)')
      expect(calls.first[:stdin]).to start_with('/deep-review')
      expect(File).not_to exist(File.join(tmp_dir, 'log/thingie-claude-code.json'))
    end
  end

  context 'when raw_output_file points outside the project' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), "[claude_code]\nraw_output_file = \"../escape.json\"\n")
    end

    it 'refuses to write it' do
      expect { source.call }.to raise_error(RuntimeError, /outside the project/)
    end
  end

  context 'when the raw output cannot be written' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, 'log'), '') # a file where the log directory should be
    end

    it 'warns and still returns the findings', :aggregate_failures do
      issues = nil
      expect { issues = source.call }.to output(/could not write/).to_stderr
      expect(issues.size).to eq(2)
    end
  end

  context 'when the CLI fails' do
    let(:status) { instance_double(Process::Status, success?: false, exitstatus: 1) }
    let(:runner) { ->(*) { ['', 'Not logged in', status] } }

    it 'raises with the stderr' do
      expect { source.call }.to raise_error(RuntimeError, /exited 1: Not logged in/)
    end

    context 'when the CLI reports the failure in its JSON result instead' do
      let(:runner) do
        ->(*) { [JSON.generate('is_error' => true, 'result' => 'API Error: 401 API key is invalid'), '', status] }
      end

      it 'raises with that reason' do
        expect { source.call }.to raise_error(RuntimeError, /exited 1: API Error: 401 API key is invalid/)
      end
    end
  end

  context 'when the CLI exits cleanly without a JSON result' do
    let(:stdout) { "Update available: run claude update\n" }

    it 'raises, pointing at the saved output' do
      expect { source.call }
        .to raise_error(RuntimeError, %r{printed no JSON result \(saved to .*log/thingie-claude-code})
    end
  end

  context 'when a log line precedes the JSON result' do
    let(:stdout) { "Update available: run claude update\n#{JSON.generate(cli_result)}" }

    it 'still parses the result' do
      expect(source.call.size).to eq(2)
    end
  end

  context 'when the run ends without structured output' do
    let(:cli_result) { { 'result' => 'budget reached', 'total_cost_usd' => 5.0 } }

    it 'raises instead of reporting a clean review' do
      expect { source.call }.to raise_error(RuntimeError, /no findings JSON/)
    end
  end

  context 'when the output echoes a credential' do
    let(:cli_result) { super().merge('result' => 'The key is sk-or-secret-value-1234567890') }

    before { Thingie::Env['ANTHROPIC_AUTH_TOKEN'] = 'sk-or-secret-value-1234567890' }

    it 'refuses to use the result' do
      expect { source.call }.to raise_error(RuntimeError, /contains the value of ANTHROPIC_AUTH_TOKEN/)
    end
  end

  context 'when the output names the configured default model' do
    before { Thingie::Env['ANTHROPIC_DEFAULT_SONNET_MODEL'] = 'anthropic/claude-sonnet-5-5' }

    it 'is not mistaken for a leaked secret' do
      expect(source.call.size).to eq(2)
    end
  end

  describe 'the default runner' do
    subject(:source) do
      described_class.new(config: config, changeset: changeset, prompt_builder: Thingie::PromptBuilder.new(config),
                          usage: usage)
    end

    let(:script) { File.join(tmp_dir, 'fake-claude') }

    before do
      Thingie::Env.store.merge!('PATH' => ENV.fetch('PATH'), 'LLM_API_KEY' => 'not-for-the-child',
                                'ANTHROPIC_API_KEY' => 'sk-ant-child-key-1234567890')
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        sleep ENV.fetch('FAKE_SLEEP', '0').to_f
        prompt = $stdin.read
        result = #{cli_result.to_json.inspect}
        result = result.sub('Two findings', "Prompt \#{prompt.lines.first.strip} in \#{Dir.pwd} \#{ENV.key?('LLM_API_KEY')}")
        puts result
      RUBY
      File.chmod(0o755, script)
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'),
                 "[claude_code]\ncommand = #{script.inspect}\ntimeout = 1\n")
    end

    it 'runs the command in the repo with the prompt on stdin and only the CLI env', :aggregate_failures do
      issues = source.call
      expect(issues.size).to eq(2)
      expect(source.details['notes'])
        .to eq("Prompt /code-review in #{File.realpath(tmp_dir)} false survived verification.")
    end

    it 'kills the command when it exceeds the timeout' do
      Thingie::Env['CLAUDE_FAKE_SLEEP'] = '5' # forwarded under the CLAUDE_ prefix
      File.write(script, File.read(script).sub("ENV.fetch('FAKE_SLEEP'", "ENV.fetch('CLAUDE_FAKE_SLEEP'"))
      expect { source.call }.to raise_error(RuntimeError, /timed out after 1s/)
    end
  end

  describe '.selected?' do
    it 'is false by default' do
      expect(described_class.selected?(config)).to be(false)
    end

    it 'follows REVIEW_SOURCE over the config' do
      Thingie::Env['REVIEW_SOURCE'] = 'claude_code'
      expect(described_class.selected?(config)).to be(true)
    end

    it 'follows [review] source in the project config' do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), "[review]\nsource = \"claude_code\"\n")
      expect(described_class.selected?(config)).to be(true)
    end

    it 'treats a blank REVIEW_SOURCE as unset, like the other env overrides' do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), "[review]\nsource = \"claude_code\"\n")
      Thingie::Env['REVIEW_SOURCE'] = ''
      expect(described_class.selected?(config)).to be(true)
    end
  end
end
