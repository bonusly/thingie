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
                                        workdir: tmp_dir)
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
    expect(call[:argv].first(4)).to eq(['claude', '-p', '--output-format', 'json'])
    expect(call[:argv]).to include('--json-schema', '--max-budget-usd', '5.0', '--permission-mode', 'dontAsk')
    schema = JSON.parse(call[:argv][call[:argv].index('--json-schema') + 1])
    expect(schema.dig('properties', 'issues', 'items', 'required')).to include('file', 'severity', 'affected_lines')
    expect(call[:argv][call[:argv].index('--allowedTools') + 1])
      .to eq(config['claude_code']['allowed_tools'].join(','))
    expect(call[:argv][call[:argv].index('--disallowedTools') + 1]).to include('Read(./.git/**)', 'Read(//proc/**)')
    expect(call[:stdin]).to start_with('/code-review')
    expect(call[:stdin]).to include('`main`', '- app.rb', '- lib/b.rb', '1 — Critical')
  end

  it 'records the run cost and tokens into the shared usage', :aggregate_failures do
    source.call
    expect(usage.cost).to eq(0.42)
    expect(usage.input_tokens).to eq(1000)
    expect(usage.output_tokens).to eq(200)
    expect(usage.cache_read_tokens).to eq(50)
    expect(usage.cache_write_tokens).to eq(10)
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
        a_string_including('1 finding(s) for `config/locales/en.yml`, which is not in the changeset'),
        a_string_including('malformed Claude Code finding for app.rb')
      )
    end
  end

  context 'when the project leaves the model and turn cap at their TOML defaults' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), "[claude_code]\nmodel = \"\"\nmax_turns = 0\n")
    end

    it 'lets the CLI pick, rather than passing empty flags' do
      source.call
      expect(calls.first[:argv]).not_to include('--model', '--max-turns')
    end
  end

  context 'when the project overrides the settings' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie/config.toml'), <<~TOML)
        [claude_code]
        skill = "/deep-review"
        model = "claude-opus-5-5"
        max_turns = 40
        raw_output_file = ""
      TOML
    end

    it 'passes them to the CLI', :aggregate_failures do
      source.call
      argv = calls.first[:argv]
      expect(argv).to include('--model', 'claude-opus-5-5', '--max-turns', '40')
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
      expect { source.call }.to raise_error(RuntimeError, /must be inside the project/)
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
      expect { source.call }.to raise_error(RuntimeError, /no structured output/)
    end
  end

  context 'when the output echoes the API key' do
    let(:cli_result) { super().merge('result' => 'The key is sk-ant-secret-value-1234567890') }

    before { Thingie::Env['ANTHROPIC_API_KEY'] = 'sk-ant-secret-value-1234567890' }

    it 'refuses to use the result' do
      expect { source.call }.to raise_error(RuntimeError, /contains the value of ANTHROPIC_API_KEY/)
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
