# frozen_string_literal: true

require 'logger'
require_relative 'server_config'
require_relative '../llm_client'

module Thingie
  module Mcp
    # Owns the lifecycle of configured MCP clients and exposes their tools,
    # mirroring {Thingie::Lsp::Client}'s role for external tool providers.
    # Construction is fail-open: a server that can't resolve secrets, start, or
    # list tools is skipped with a warning (collected in {#warnings}) and the
    # review proceeds without it — same philosophy as the Verifier.
    #
    # `ruby_llm/mcp` is required lazily, so non-MCP users never pay the
    # `httpx`/`json-schema`/`json_schemer` load cost on startup.
    class Toolset
      class << self
        # Idempotent guard so gem logging is rerouted at most once per process.
        @logging_configured = false

        # Builds clients for every configured server. Never raises for a bad
        # server: failures become warnings and that server is skipped.
        #
        # @param config [Thingie::Configuration] the resolved run configuration
        # @return [Thingie::Mcp::Toolset] a toolset (possibly empty) with warnings
        def build(config)
          result = ServerConfig.load(config)
          toolset = new(result.warnings)
          return toolset if result.servers.empty?

          require 'ruby_llm/mcp'
          configure_logging(config)
          toolset.build_clients(result.servers)
          toolset
        end

        # Reroutes gem logging away from its $stdout/INFO default so it can't
        # pollute the CLI report. When Thingie's `log_file` is set, logs go there
        # at the configured level; otherwise to `File::NULL` at WARN. Idempotent.
        #
        # @param config [Thingie::Configuration] the resolved run configuration
        # @return [void]
        def configure_logging(config)
          return if @logging_configured

          log_file = config['log_file']
          if log_file && !log_file.to_s.empty?
            level = Thingie::LlmClient::LOG_LEVELS[config['log_level']] || Logger::INFO
          else
            log_file = File::NULL
            level = Logger::WARN
          end
          RubyLLM::MCP.configure do |mcp|
            mcp.log_file = log_file
            mcp.log_level = level
          end
          @logging_configured = true
        end
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

      # Stops every live client. Never raises — a stuck server must not abort
      # the review shutdown path.
      #
      # @return [void]
      def shutdown
        @clients.each do |client|
          client.stop if client.alive?
        rescue StandardError
          nil
        end
      end

      # Starts each server and collects its (filtered) tools. A server whose
      # construction, start, or tool listing raises is skipped with a warning.
      #
      # @param servers [Array<Hash>] normalized option hashes from {ServerConfig}
      # @return [void]
      def build_clients(servers)
        servers.each do |server|
          client = build_client(server)
          next unless client

          @clients << client
          @tools.concat(filter_tools(server, client.tools))
        end
      end

      private

      # Constructs and starts one client. Returns nil (and records a warning)
      # on any failure, stopping a partially-started client first.
      #
      # @param server [Hash] a normalized option hash
      # @return [RubyLLM::MCP::Client, nil] the started client, or nil on failure
      def build_client(server)
        client = nil
        kwargs = { name: server[:name], transport_type: server[:transport_type],
                   start: false, config: server[:config] }
        kwargs[:request_timeout] = server[:request_timeout] if server[:request_timeout]
        client = RubyLLM::MCP.client(**kwargs)
        client.start
        client
      rescue StandardError => e
        @warnings << "MCP server '#{server[:name]}' unavailable: #{e.class}: #{e.message}"
        client&.stop if client&.alive?
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
