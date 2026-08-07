# frozen_string_literal: true

require 'json'
require 'yaml'

module Thingie
  module Mcp
    # Normalizes `[mcp.<name>]` TOML tables (from {Thingie::Configuration#mcp_servers})
    # and `.thingie/mcp.{yml,yaml,json}` entries (from
    # {Thingie::Configuration#mcp_config_file}) into ruby_llm-mcp client options,
    # interpolating `${VAR}` placeholders via {Thingie::Env} (so `~/.thingie/.env`
    # values apply and specs stay isolated). Pure parsing — no gem dependency,
    # fully unit-testable. {Thingie::Mcp::Toolset} consumes the result.
    class ServerConfig
      # Outcome of {ServerConfig.load}: the normalized server option hashes and
      # any non-fatal warnings recorded for misconfigured/skipped servers.
      Result = Data.define(:servers, :warnings)

      # Keys forwarded into the gem's `config:` hash (symbolized top-level;
      # nested `env`/`headers` keep their string keys verbatim).
      GEM_CONFIG_KEYS = %w[command args env url headers oauth protocol_version with_prefix].freeze

      # Thingie-level keys consumed here, never seen by the gem.
      THINGIE_KEYS = %w[enabled request_timeout include_tools exclude_tools].freeze

      # Transport names the gem accepts (a subset of its VALID_TRANSPORTS).
      TRANSPORTS = %w[stdio sse streamable].freeze

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

          transport_type = resolve_transport(name, interpolated, warnings)
          return nil unless transport_type

          {
            name: name,
            transport_type: transport_type,
            request_timeout: interpolated['request_timeout'],
            include_tools: Array(interpolated['include_tools']),
            exclude_tools: Array(interpolated['exclude_tools']),
            config: gem_config(interpolated)
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

        # Builds the gem `config:` hash: only present gem-level keys, symbolized
        # at the top level. Nested `env`/`headers` hashes are copied verbatim
        # (string keys) — they become process env / HTTP headers as written.
        def gem_config(entry)
          GEM_CONFIG_KEYS.each_with_object({}) do |key, acc|
            acc[key.to_sym] = entry[key] if entry.key?(key)
          end
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
