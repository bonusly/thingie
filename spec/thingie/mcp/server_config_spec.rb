# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'thingie/mcp/server_config'

RSpec.describe Thingie::Mcp::ServerConfig do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) { Thingie::Configuration.new(root: tmp_dir) }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_project_config(toml)
    FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
    File.write(File.join(tmp_dir, '.thingie', 'config.toml'), toml)
  end

  def write_mcp_file(name, content)
    FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
    File.write(File.join(tmp_dir, '.thingie', name), content)
  end

  describe '.load' do
    it 'returns an empty result with no servers configured' do
      result = described_class.load(config)
      expect(result.servers).to eq([])
      expect(result.warnings).to eq([])
    end

    context 'with transport inference' do
      it 'infers stdio from command' do
        write_project_config(<<~TOML)
          [mcp.fs]
          command = "npx"
          args = ["-y", "@modelcontextprotocol/server-filesystem", "."]
        TOML
        server = described_class.load(config).servers.first
        expect(server[:transport_type]).to eq(:stdio)
      end

      it 'infers streamable from url' do
        write_project_config(<<~TOML)
          [mcp.docs]
          url = "https://example.com/mcp"
        TOML
        server = described_class.load(config).servers.first
        expect(server[:transport_type]).to eq(:streamable)
      end
    end

    context 'with explicit transport' do
      it 'maps sse transport' do
        write_project_config(<<~TOML)
          [mcp.docs]
          transport = "sse"
          url = "https://example.com/mcp"
        TOML
        server = described_class.load(config).servers.first
        expect(server[:transport_type]).to eq(:sse)
      end

      it 'warns and skips an unknown transport' do
        write_project_config(<<~TOML)
          [mcp.bad]
          transport = "carrier-pigeon"
          command = "npx"
        TOML
        result = described_class.load(config)
        expect(result.servers).to eq([])
        expect(result.warnings).to include("MCP server 'bad' skipped: unknown transport 'carrier-pigeon'")
      end
    end

    it 'warns and skips when neither command nor url is present' do
      write_project_config(<<~TOML)
        [mcp.empty]
        enabled = true
      TOML
      result = described_class.load(config)
      expect(result.servers).to eq([])
      expect(result.warnings).to include(
        'MCP server \'empty\' skipped: no inferable transport (set `command` or `url`)'
      )
    end

    it 'silently skips an explicitly disabled server' do
      write_project_config(<<~TOML)
        [mcp.disabled]
        enabled = false
        command = "npx"
      TOML
      result = described_class.load(config)
      expect(result.servers).to eq([])
      expect(result.warnings).to eq([])
    end

    context 'with ${VAR} interpolation' do
      before { Thingie::Env['GITHUB_TOKEN'] = 'secret-token' }

      it 'resolves vars inside nested env and headers hashes and args arrays' do
        write_project_config(<<~TOML)
          [mcp.github]
          command = "npx"
          args = ["-y", "@modelcontextprotocol/server-github", "--token=${GITHUB_TOKEN}"]
          env = { GITHUB_PERSONAL_ACCESS_TOKEN = "${GITHUB_TOKEN}" }

          [mcp.docs]
          transport = "streamable"
          url = "https://example.com/mcp"
          headers = { Authorization = "Bearer ${GITHUB_TOKEN}" }
        TOML
        servers = described_class.load(config).servers
        github = servers.find { |s| s[:name] == 'github' }
        docs = servers.find { |s| s[:name] == 'docs' }
        expect(github[:config][:args].last).to eq('--token=secret-token')
        expect(github[:config][:env]['GITHUB_PERSONAL_ACCESS_TOKEN']).to eq('secret-token')
        expect(docs[:config][:headers]['Authorization']).to eq('Bearer secret-token')
      end

      it 'skips the server and warns when a var is unset' do
        write_project_config(<<~TOML)
          [mcp.unset]
          command = "npx"
          env = { FAKE = "${THIS_VAR_IS_UNSET}" }
        TOML
        result = described_class.load(config)
        expect(result.servers).to eq([])
        expect(result.warnings).to include(
          "MCP server 'unset' skipped: environment variable THIS_VAR_IS_UNSET is not set"
        )
      end
    end

    it 'strips thingie-level keys from the gem config hash' do
      write_project_config(<<~TOML)
        [mcp.fs]
        command = "npx"
        args = ["-y", "server-fs"]
        enabled = true
        request_timeout = 5000
        include_tools = ["read_file"]
        exclude_tools = ["delete_file"]
      TOML
      server = described_class.load(config).servers.first
      expect(server[:request_timeout]).to eq(5000)
      expect(server[:include_tools]).to eq(['read_file'])
      expect(server[:exclude_tools]).to eq(['delete_file'])
      expect(server[:config]).not_to have_key(:enabled)
      expect(server[:config]).not_to have_key(:request_timeout)
      expect(server[:config]).not_to have_key(:include_tools)
      expect(server[:config]).not_to have_key(:exclude_tools)
    end

    it 'keeps string keys inside nested env and headers hashes' do
      write_project_config(<<~TOML)
        [mcp.s]
        command = "npx"
        env = { API_KEY = "literal" }
      TOML
      env = described_class.load(config).servers.first[:config][:env]
      expect(env).to have_key('API_KEY')
      expect(env).not_to have_key(:API_KEY)
    end

    context 'with a standalone mcp.yml file' do
      it 'parses servers from mcp.yml' do
        write_mcp_file('mcp.yml', <<~YAML)
          mcp_servers:
            fs:
              transport_type: stdio
              command: npx
              args: ["-y", "server-fs"]
        YAML
        server = described_class.load(config).servers.first
        expect(server[:name]).to eq('fs')
        expect(server[:transport_type]).to eq(:stdio)
        expect(server[:config][:command]).to eq('npx')
      end

      it 'parses servers from mcp.json' do
        write_mcp_file('mcp.json', <<~JSON)
          {"mcp_servers": {"fs": {"transport_type": "stdio", "command": "npx"}}}
        JSON
        server = described_class.load(config).servers.first
        expect(server[:name]).to eq('fs')
        expect(server[:transport_type]).to eq(:stdio)
      end
    end

    context 'with duplicate names across toml and yml' do
      it 'lets config.toml win' do
        write_project_config(<<~TOML)
          [mcp.shared]
          command = "from-toml"
        TOML
        write_mcp_file('mcp.yml', <<~YAML)
          mcp_servers:
            shared:
              command: from-yaml
        YAML
        server = described_class.load(config).servers.first
        expect(server[:config][:command]).to eq('from-toml')
      end
    end

    it 'prefers mcp.yml over mcp.yaml over mcp.json' do
      write_mcp_file('mcp.yaml', "mcp_servers:\n  yaml_one:\n    command: from-yaml\n")
      write_mcp_file('mcp.json', '{"mcp_servers":{"json_one":{"command":"from-json"}}}')
      server = described_class.load(config).servers.first
      expect(server[:name]).to eq('yaml_one')
    end
  end
end
