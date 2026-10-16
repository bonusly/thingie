# frozen_string_literal: true

require 'json'
require 'yaml'

module Thingie
  module Mcp
    # Normalizes `[mcp.<name>]` TOML tables (from {Thingie::Configuration#mcp_servers})
    # and `.thingie/mcp.{yml,yaml,json}` entries (from
    # {Thingie::Configuration#mcp_config_file}) into `RubyLLM.mcp` settings,
    # interpolating `${VAR}` placeholders via {Thingie::Env} (so `~/.thingie/.env`
    # values apply and specs stay isolated). Pure parsing, fully unit-testable.
    # {Thingie::Mcp::Toolset} consumes the result.
    class ServerConfig
      # Outcome of {ServerConfig.load}: the normalized server option hashes and
      # any non-fatal warnings recorded for misconfigured/skipped servers.
      Result = Data.define(:servers, :warnings)

      # Transports the built-in client supports: `stdio` (command) and `streamable` (url).
      TRANSPORTS = %w[stdio streamable].freeze

      VAR_PATTERN = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

      # Loads and normalizes every configured MCP server from both sources,
      # skipping misconfigured ones with a recorded warning (fail-open).
      # Project TOML entries win over standalone-file entries on duplicate names.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @return [Thingie::Mcp::ServerConfig::Result] normalized servers + warnings
      def self.load(config)
        warnings = []
        merged = parse_file(config).merge(config.mcp_servers)
        servers = merged.filter_map do |name, entry|
          normalize(name, entry, warnings)
        end
        Result.new(servers: servers, warnings: warnings)
      end

      class << self
        private

        # Parses the standalone MCP config file (if any) into a name => entry
        # hash with string keys. Returns {} when no file exists or it lacks
        # `mcp_servers`. No ERB evaluation — avoids arbitrary code execution.
        def parse_file(config)
          path = config.mcp_config_file or return {}
          raw = File.read(path)
          data = File.extname(path) == '.json' ? JSON.parse(raw) : YAML.safe_load(raw)
          servers = data&.fetch('mcp_servers', nil) || {}
          servers.transform_keys(&:to_s)
        rescue StandardError => e
          warn "MCP config file '#{path}' unreadable: #{e.class}: #{e.message}"
          {}
        end

        # Normalizes one raw entry into a server option hash, or nil to skip.
        def normalize(name, entry, warnings)
          return malformed(name, entry, warnings) unless entry.is_a?(Hash)

          return nil if entry['enabled'] == false # explicit disable: silent skip

          interpolated, unresolved = interpolate(entry)
          if unresolved
            warnings << "MCP server '#{name}' skipped: environment variable #{unresolved} is not set"
            return nil
          end

          return nil unless resolve_transport(name, interpolated, warnings)

          {
            name: name,
            include_tools: Array(interpolated['include_tools']),
            exclude_tools: Array(interpolated['exclude_tools']),
            settings: settings(name, interpolated)
          }
        end

        def malformed(name, entry, warnings)
          warnings << "MCP server '#{name}' skipped: entry must be a table, got #{entry.class}"
          nil
        end

        # Resolves the transport symbol, inferring from `command`/`url` when the
        # `transport`/`transport_type` key is absent. Pushes a warning and returns
        # nil for unknown values or uninferable entries.
        def resolve_transport(name, entry, warnings)
          value = entry['transport'] || entry['transport_type']
          if value
            return value.to_sym if TRANSPORTS.include?(value.to_s)

            warnings << "MCP server '#{name}' skipped: unknown transport '#{value}'"
            return nil
          end
          return :stdio if entry.key?('command')
          return :streamable if entry.key?('url')

          warnings << "MCP server '#{name}' skipped: no inferable transport (set `command` or `url`)"
          nil
        end

        # Builds the `RubyLLM.mcp` keywords from the present keys. A CLI review can't answer a
        # server's input requests, so they are always off. `request_timeout` is in ms; the client
        # wants seconds. `protocol_version` has no equivalent and is ignored.
        def settings(name, entry)
          settings = { name: name, input_requests: false }
          settings[:command] = [entry['command'], *Array(entry['args'])] if entry.key?('command')
          settings[:url] = entry['url'] if entry.key?('url')
          settings[:headers] = entry['headers'] if entry.key?('headers')
          settings[:env] = entry['env'].transform_keys(&:to_sym) if entry.key?('env')
          settings[:timeout] = entry['request_timeout'] / 1000.0 if entry.key?('request_timeout')
          settings[:prefix] = name if entry['with_prefix'] == true
          settings[:oauth] = oauth(entry['oauth']) if entry.key?('oauth')
          settings
        end

        # `oauth = true` or a table of `RubyLLM::MCP.oauth` keywords.
        def oauth(value)
          value.is_a?(Hash) ? value.transform_keys(&:to_sym) : value
        end

        # Recursively interpolates `${VAR}` in every String value (in hashes,
        # arrays, and scalars), resolving through {Thingie::Env}. Returns the
        # interpolated structure plus the first unresolved variable name (or nil
        # if all resolved). One unresolved variable skips the whole server.
        def interpolate(value)
          case value
          when Hash
            unresolved = nil
            result = value.to_h do |k, v|
              r, u = interpolate(v)
              unresolved ||= u
              [k, r]
            end
            [result, unresolved]
          when Array
            unresolved = nil
            result = value.map do |v|
              r, u = interpolate(v)
              unresolved ||= u
              r
            end
            [result, unresolved]
          when String
            interpolate_string(value)
          else
            [value, nil]
          end
        end

        def interpolate_string(string)
          unresolved = nil
          result = string.gsub(VAR_PATTERN) do |match|
            var = Regexp.last_match(1)
            replacement = Thingie::Env[var]
            if replacement.nil?
              unresolved ||= var
              match
            else
              replacement
            end
          end
          [result, unresolved]
        end
      end
    end
  end
end
