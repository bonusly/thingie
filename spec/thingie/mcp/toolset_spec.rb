# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
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
    instance_double(RubyLLM::MCP, tools: tools, close: nil)
  end

  describe '.build' do
    it 'returns an empty toolset without calling RubyLLM.mcp when no servers' do
      allow(RubyLLM).to receive(:mcp)
      toolset = described_class.build(config)
      expect(toolset.tools).to eq([])
      expect(toolset.any?).to be(false)
      expect(RubyLLM).not_to have_received(:mcp)
    end

    it 'aggregates tools across servers' do
      write_project_config(<<~TOML)
        [mcp.alpha]
        command = "npx"

        [mcp.beta]
        command = "npx"
      TOML
      allow(RubyLLM).to receive(:mcp).with(name: 'alpha', command: ['npx'], input_requests: false)
                                     .and_return(fake_client(tools: [tool_double('a_one')]))
      allow(RubyLLM).to receive(:mcp).with(name: 'beta', command: ['npx'], input_requests: false)
                                     .and_return(fake_client(tools: [tool_double('b_one'), tool_double('b_two')]))
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
      allow(RubyLLM).to receive(:mcp).and_return(
        fake_client(tools: [tool_double('keep'), tool_double('also_keep'), tool_double('drop')])
      )
      toolset = described_class.build(config)
      expect(toolset.tools.map(&:name)).to eq(['keep'])
    end

    it 'skips a server whose tool listing raises while keeping the others', :aggregate_failures do
      write_project_config(<<~TOML)
        [mcp.broken]
        command = "definitely-not-a-binary"

        [mcp.ok]
        command = "npx"
      TOML
      broken = instance_double(RubyLLM::MCP, close: nil)
      allow(broken).to receive(:tools).and_raise(RubyLLM::MCP::Error, 'boom')
      allow(RubyLLM).to receive(:mcp).with(name: 'broken', command: ['definitely-not-a-binary'], input_requests: false)
                                     .and_return(broken)
      allow(RubyLLM).to receive(:mcp).with(name: 'ok', command: ['npx'], input_requests: false)
                                     .and_return(fake_client(tools: [tool_double('survivor')]))
      toolset = described_class.build(config)
      expect(toolset.tools.map(&:name)).to eq(['survivor'])
      expect(toolset.warnings).to include("MCP server 'broken' unavailable: RubyLLM::MCP::Error: boom")
      expect(broken).to have_received(:close)
    end

    it 'shutdown closes every client' do
      write_project_config(<<~TOML)
        [mcp.a]
        command = "npx"

        [mcp.b]
        command = "npx"
      TOML
      client_a = fake_client(tools: [tool_double('a')])
      client_b = fake_client(tools: [tool_double('b')])
      allow(RubyLLM).to receive(:mcp).and_return(client_a, client_b)
      toolset = described_class.build(config)
      toolset.shutdown
      expect(client_a).to have_received(:close)
      expect(client_b).to have_received(:close)
    end
  end
end
