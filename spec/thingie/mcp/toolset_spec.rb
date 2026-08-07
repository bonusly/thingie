# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'ruby_llm/mcp'
require 'thingie/mcp/toolset'

RSpec.describe Thingie::Mcp::Toolset do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) { Thingie::Configuration.new(root: tmp_dir) }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_project_config(toml)
    FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
    File.write(File.join(tmp_dir, '.thingie', 'config.toml'), toml)
  end

  def tool_double(name)
    instance_double(RubyLLM::MCP::Tool, name: name)
  end

  def fake_client(tools: [])
    client = instance_double(RubyLLM::MCP::Client)
    allow(client).to receive_messages(start: nil, stop: nil, alive?: true, tools: tools)
    client
  end

  describe '.build' do
    it 'returns an empty toolset without calling RubyLLM::MCP.client when no servers' do
      allow(RubyLLM::MCP).to receive(:client)
      toolset = described_class.build(config)
      expect(toolset.tools).to eq([])
      expect(toolset.any?).to be(false)
      expect(RubyLLM::MCP).not_to have_received(:client)
    end

    it 'aggregates tools across servers' do
      write_project_config(<<~TOML)
        [mcp.alpha]
        command = "npx"

        [mcp.beta]
        command = "npx"
      TOML
      allow(RubyLLM::MCP).to receive(:client).with(name: 'alpha', transport_type: :stdio,
                                                   start: false, config: { command: 'npx' })
                                             .and_return(fake_client(tools: [tool_double('a_one')]))
      allow(RubyLLM::MCP).to receive(:client).with(name: 'beta', transport_type: :stdio,
                                                   start: false, config: { command: 'npx' })
                                             .and_return(fake_client(tools: [tool_double('b_one'),
                                                                             tool_double('b_two')]))
      toolset = described_class.build(config)
      expect(toolset.tools.map(&:name)).to contain_exactly('a_one', 'b_one', 'b_two')
      expect(toolset.any?).to be(true)
    end

    it 'applies include_tools then exclude_tools' do
      write_project_config(<<~TOML)
        [mcp.fs]
        command = "npx"
        include_tools = ["keep", "also_keep"]
        exclude_tools = ["also_keep"]
      TOML
      allow(RubyLLM::MCP).to receive(:client).and_return(
        fake_client(tools: [tool_double('keep'), tool_double('also_keep'), tool_double('drop')])
      )
      toolset = described_class.build(config)
      expect(toolset.tools.map(&:name)).to eq(['keep'])
    end

    it 'skips a server whose start raises while keeping the others' do
      write_project_config(<<~TOML)
        [mcp.broken]
        command = "definitely-not-a-binary"

        [mcp.ok]
        command = "npx"
      TOML
      broken = instance_double(RubyLLM::MCP::Client)
      allow(broken).to receive(:start).and_raise(StandardError, 'boom')
      allow(broken).to receive_messages(alive?: false, stop: nil)
      allow(RubyLLM::MCP).to receive(:client).with(name: 'broken', transport_type: :stdio,
                                                   start: false, config: { command: 'definitely-not-a-binary' })
                                             .and_return(broken)
      allow(RubyLLM::MCP).to receive(:client).with(name: 'ok', transport_type: :stdio,
                                                   start: false, config: { command: 'npx' })
                                             .and_return(fake_client(tools: [tool_double('survivor')]))
      toolset = described_class.build(config)
      expect(toolset.tools.map(&:name)).to eq(['survivor'])
      expect(toolset.warnings).to include(match(/MCP server 'broken' unavailable.*boom/))
    end

    it 'shutdown stops every live client' do
      write_project_config(<<~TOML)
        [mcp.a]
        command = "npx"

        [mcp.b]
        command = "npx"
      TOML
      client_a = fake_client(tools: [tool_double('a')])
      client_b = fake_client(tools: [tool_double('b')])
      allow(RubyLLM::MCP).to receive(:client).and_return(client_a, client_b)
      toolset = described_class.build(config)
      toolset.shutdown
      expect(client_a).to have_received(:stop)
      expect(client_b).to have_received(:stop)
    end
  end
end
