# frozen_string_literal: true

require 'ruby_llm'
require_relative 'server_config'

module Thingie
  module Mcp
    # Owns the lifecycle of configured MCP clients and exposes their tools,
    # mirroring {Thingie::Lsp::Client}'s role for external tool providers.
    # Construction is fail-open: a server that can't resolve secrets, start, or
    # list tools is skipped with a warning (collected in {#warnings}) and the
    # review proceeds without it — same philosophy as the Verifier.
    class Toolset
      # Builds clients for every configured server. Never raises for a bad
      # server: failures become warnings and that server is skipped.
      #
      # @param config [Thingie::Configuration] the resolved run configuration
      # @return [Thingie::Mcp::Toolset] a toolset (possibly empty) with warnings
      def self.build(config)
        result = ServerConfig.load(config)
        toolset = new(result.warnings)
        return toolset if result.servers.empty?

        toolset.build_clients(result.servers)
        toolset
      end

      # Builds a toolset seeded with warnings already recorded by {ServerConfig}.
      #
      # @param warnings [Array<String>] warnings already recorded by {ServerConfig}
      def initialize(warnings = [])
        @warnings = warnings
        @clients = []
        @tools = []
      end

      # Warnings from parsing and from any server that failed to start.
      #
      # @return [Array<String>] human-readable warning messages
      attr_reader :warnings

      # The aggregated, filtered MCP tools ready to pass to an LLM call.
      #
      # @return [Array<Object>] RubyLLM-compatible MCP tool objects
      attr_reader :tools

      # True when at least one MCP tool is available.
      #
      # @return [Boolean]
      def any?
        @tools.any?
      end

      # Closes every client. Never raises — a stuck server must not abort
      # the review shutdown path.
      #
      # @return [void]
      def shutdown
        @clients.each do |client|
          client.close
        rescue StandardError
          nil
        end
      end

      # Connects to each server and collects its (filtered) tools. A server whose
      # construction or tool listing raises is skipped with a warning.
      #
      # @param servers [Array<Hash>] normalized option hashes from {ServerConfig}
      # @return [void]
      def build_clients(servers)
        servers.each do |server|
          client, tools = build_client(server)
          next unless client

          @clients << client
          @tools.concat(filter_tools(server, tools))
        end
      end

      private

      # Builds one client and lists its tools. The connection is lazy, so listing tools
      # inside the rescue is what makes a dead server fail open. Returns nil (and records
      # a warning) on any failure, closing the client first.
      #
      # @param server [Hash] a normalized option hash
      # @return [Array(RubyLLM::MCP, Array<RubyLLM::MCP::Tool>), nil] the client and its tools, or nil on failure
      def build_client(server)
        mcp = RubyLLM.mcp(**server[:settings])
        [mcp, mcp.tools]
      rescue StandardError => e
        @warnings << "MCP server '#{server[:name]}' unavailable: #{e.class}: #{e.message}"
        begin
          mcp&.close
        rescue StandardError
          nil
        end
        nil
      end

      # Applies `include_tools` (allowlist) then `exclude_tools` (denylist) by
      # tool name. When `with_prefix` was set the prefixed name is what's matched.
      #
      # @param server [Hash] a normalized option hash
      # @param tools [Array<Object>] the client's raw tool list
      # @return [Array<Object>] the filtered tool list
      def filter_tools(server, tools)
        include_tools = server[:include_tools]
        tools = tools.select { |t| include_tools.include?(t.name) } if include_tools.any?
        exclude_tools = server[:exclude_tools]
        exclude_tools.any? ? tools.reject { |t| exclude_tools.include?(t.name) } : tools
      end
    end
  end
end
