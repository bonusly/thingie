# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Configuration do
  subject(:config) { described_class.new(root: tmp_dir) }

  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  it 'loads bundled defaults', :aggregate_failures do
    expect(config['retries']).to eq(3)
    expect(config['request_timeout']).to eq(120)
    expect(config['models_file']).to eq('')
  end

  it 'exposes prompt_vars' do
    expect(config.prompt_vars).to include('self_id', 'requirements', 'json_requirements')
  end

  it 'exposes the show threshold (post_process)' do
    expect(config.show_threshold).to eq(max_severity: 4, max_confidence: 1)
  end

  it 'exposes the block threshold (approve), disabled by default' do
    expect(config.block_threshold).to eq(max_severity: 2, enabled: false)
  end

  context 'with approve enabled via project config' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', 'config.toml'), <<~TOML)
        [approve]
        enabled = true
        max_severity = 2
      TOML
    end

    it 'reflects the overridden block threshold' do
      expect(config.block_threshold).to eq(max_severity: 2, enabled: true)
    end
  end

  context 'with a project config file' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', 'config.toml'), <<~TOML)
        retries = 10
        model = "claude-sonnet-4"

        [prompt_vars]
        requirements = "Extra requirement."
      TOML
    end

    it 'overrides simple keys', :aggregate_failures do
      expect(config['retries']).to eq(10)
      expect(config['model']).to eq('claude-sonnet-4')
    end

    it 'deep-merges prompt_vars', :aggregate_failures do
      expect(config.prompt_vars['requirements']).to eq('Extra requirement.')
      expect(config.prompt_vars['self_id']).to include('AI-powered')
    end
  end

  context 'with ~/.thingie/.env' do
    let(:env_file) { File.join(tmp_dir, 'fake-home.env') }

    before do
      File.write(env_file, "LLM_API_KEY=from-dotenv-file\n")
      stub_const('Thingie::Configuration::USER_ENV_FILE', env_file)
    end

    it 'loads LLM_API_KEY from the env file' do
      expect(config['llm_api_key']).to eq('from-dotenv-file')
    end
  end

  context 'with environment variables' do
    before { Thingie::Env['LLM_MODEL'] = 'gpt-5' }

    it 'overrides model from environment' do
      expect(config['model']).to eq('gpt-5')
    end
  end

  context 'with THINGIE_MODELS_FILE environment variable' do
    before { Thingie::Env['THINGIE_MODELS_FILE'] = '/tmp/thingie-models.json' }

    it 'overrides models_file from environment' do
      expect(config['models_file']).to eq('/tmp/thingie-models.json')
    end
  end

  context 'with explicit overrides' do
    subject(:config) { described_class.new(root: tmp_dir, overrides: { model: 'o1-preview' }) }

    it 'overrides model from constructor options' do
      expect(config['model']).to eq('o1-preview')
    end
  end

  context 'with environment variable and explicit override' do
    subject(:config) { described_class.new(root: tmp_dir, overrides: { model: 'o1-preview' }) }

    before { Thingie::Env['LLM_MODEL'] = 'gpt-5' }

    it 'prefers explicit override over environment variable' do
      expect(config['model']).to eq('o1-preview')
    end
  end

  context 'with skill directories' do
    before do
      %w[.agents .claude .cursor].each do |source|
        FileUtils.mkdir_p(File.join(tmp_dir, source))
        File.write(File.join(tmp_dir, source, 'rails_rules.md'), "#{source} rule")
      end
    end

    it 'discovers markdown skill files', :aggregate_failures do
      expect(config.skills.size).to eq(3)
      expect(config.skills.map(&:name)).to contain_exactly('rails_rules', 'rails_rules', 'rails_rules')
    end

    it 'captures content and source', :aggregate_failures do
      skill = config.skills.find { |s| s.source.end_with?('.agents') }
      expect(skill.source).to end_with('.agents')
      expect(skill.content).to eq('.agents rule')
    end
  end

  describe 'SkillFragment#description' do
    def fragment(content)
      Thingie::SkillFragment.new(path: '/tmp/skill.md', content: content, source: '/tmp')
    end

    it 'uses the first non-blank line' do
      expect(fragment("\n\nAlways use strong params.\nMore detail.").description)
        .to eq('Always use strong params.')
    end

    it 'strips leading markdown heading markers' do
      expect(fragment("# Rails rules\nbody").description).to eq('Rails rules')
    end

    it 'truncates long lines' do
      description = fragment('a' * 200).description
      expect(description.length).to eq(151)
      expect(description).to end_with('…')
    end
  end

  context 'with custom skill_directories' do
    subject(:config) do
      described_class.new(root: tmp_dir, overrides: { skill_directories: ['.github'] })
    end

    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.github'))
      File.write(File.join(tmp_dir, '.github', 'review_rules.md'), 'Custom rules.')
      # Create a default skill dir that should NOT be loaded
      FileUtils.mkdir_p(File.join(tmp_dir, '.agents'))
      File.write(File.join(tmp_dir, '.agents', 'default_rules.md'), 'Default rules.')
    end

    it 'only scans configured directories', :aggregate_failures do
      expect(config.skills.map(&:name)).to eq(['review_rules'])
      expect(config.skills.map(&:source)).to all(end_with('.github'))
    end
  end

  describe '#mcp_servers' do
    it 'returns an empty hash when no mcp section is present' do
      expect(config.mcp_servers).to eq({})
    end

    context 'with [mcp.<name>] tables' do
      before do
        FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
        File.write(File.join(tmp_dir, '.thingie', 'config.toml'), <<~TOML)
          [mcp.github]
          command = "npx"

          [mcp.docs]
          url = "https://example.com/mcp"
        TOML
      end

      it 'returns the servers keyed by name', :aggregate_failures do
        expect(config.mcp_servers.keys).to contain_exactly('github', 'docs')
        expect(config.mcp_servers['github']['command']).to eq('npx')
      end
    end

    it 'returns an empty hash when mcp is not a table' do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', 'config.toml'), "mcp = [1, 2, 3]\n")
      expect(config.mcp_servers).to eq({})
    end
  end

  describe '#mcp_config_file' do
    def write_mcp_file(name)
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', name), "mcp_servers: {}\n")
    end

    it 'returns nil when no mcp config file exists' do
      expect(config.mcp_config_file).to be_nil
    end

    it 'finds mcp.yml' do
      write_mcp_file('mcp.yml')
      expect(config.mcp_config_file).to end_with('mcp.yml')
    end

    it 'finds mcp.yaml' do
      write_mcp_file('mcp.yaml')
      expect(config.mcp_config_file).to end_with('mcp.yaml')
    end

    it 'finds mcp.json' do
      write_mcp_file('mcp.json')
      expect(config.mcp_config_file).to end_with('mcp.json')
    end

    it 'prefers yml over yaml and json' do
      write_mcp_file('mcp.yaml')
      write_mcp_file('mcp.json')
      write_mcp_file('mcp.yml')
      expect(config.mcp_config_file).to end_with('mcp.yml')
    end

    it 'prefers yaml over json' do
      write_mcp_file('mcp.yaml')
      write_mcp_file('mcp.json')
      expect(config.mcp_config_file).to end_with('mcp.yaml')
    end
  end
end
