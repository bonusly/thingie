# frozen_string_literal: true

require 'tomlrb'
require 'dotenv'

module Thingie
  # MCP server config accessors, extracted from {Configuration} to keep that
  # class under RuboCop's ClassLength limit. Mixed in via `include McpConfig`,
  # so it reads `@data` and `@root` as instance variables of the host class.
  module McpConfig
    # The `[mcp.<name>]` tables from project config, keyed by server name.
    # Returns an empty hash when absent or `mcp` isn't a table, so callers
    # iterate safely.
    #
    # @return [Hash{String=>Hash}] server name => raw TOML table
    def mcp_servers
      @data['mcp'].is_a?(Hash) ? @data['mcp'] : {}
    end

    # Path to a standalone `.thingie/mcp.{yml,yaml,json}` file (yml > yaml >
    # json precedence), or nil when none exists — mirroring {#project_config_path}.
    #
    # @return [String, nil] absolute path to the first matching file, or nil
    def mcp_config_file
      candidates = %w[mcp.yml mcp.yaml mcp.json].map { |n| File.join(@root, '.thingie', n) }
      candidates.find { |path| File.file?(path) }
    end
  end

  # Loads and merges Thingie configuration.
  #
  # Layers (later layers override earlier ones):
  # 1. Bundled defaults from lib/thingie/config/default.toml
  # 2. Project-specific .thingie/config.toml
  # 3. ~/.thingie/.env (loaded into ENV via dotenv)
  # 4. OS environment variables
  # 5. Explicit overrides passed to Configuration.new
  class Configuration
    attr_reader :data, :root

    include McpConfig

    # Expanded lazily in load_user_env_file so a missing/unresolvable home
    # directory can't crash at load time.
    USER_ENV_FILE = '~/.thingie/.env'

    DEFAULT_SKILL_DIRECTORIES = %w[.agents .claude .cursor].freeze

    ENV_OVERRIDES = {
      'model' => 'LLM_MODEL',
      'provider' => 'LLM_PROVIDER',
      'llm_api_key' => 'LLM_API_KEY',
      'llm_api_base' => 'LLM_API_BASE',
      'github_token' => 'GITHUB_TOKEN',
      'log_file' => 'THINGIE_LOG_FILE',
      'log_level' => 'THINGIE_LOG_LEVEL',
      'models_file' => 'THINGIE_MODELS_FILE'
    }.freeze

    INTEGER_ENV_OVERRIDES = {
      'retries' => 'LLM_RETRIES',
      'request_timeout' => 'LLM_REQUEST_TIMEOUT',
      'max_concurrent_tasks' => 'MAX_CONCURRENT_TASKS'
    }.freeze

    # Build the merged configuration for a project by loading and combining all layers
    # (bundled defaults, `.thingie/config.toml`, `~/.thingie/.env`, OS env vars, explicit overrides).
    #
    # @param root [String] project root used to locate `.thingie/config.toml`; defaults to the current directory
    # @param overrides [Hash] explicit key/value overrides, applied last and taking highest precedence
    def initialize(root: Dir.pwd, overrides: {})
      @root = root
      @overrides = overrides.transform_keys(&:to_s)
      @data = build_data
    end

    # Fetch a top-level config value by key.
    #
    # @param key [String, Symbol] config key, e.g. `` `model` `` or `` `provider` ``
    # @return [Object, nil] the value, or nil if absent
    def [](key)
      @data[key.to_s]
    end

    # Fetch a nested config value by a sequence of keys, like `Hash#dig`.
    #
    # @param keys [Array<String, Symbol>] path of keys to traverse
    # @return [Object, nil] the value, or nil if any key in the path is absent
    def dig(*keys)
      @data.dig(*keys.map(&:to_s))
    end

    # The `` `prompt_vars` `` config section, deep-merged across all layers.
    #
    # @return [Hash] template variables available to the ERB prompt templates
    def prompt_vars
      @data.fetch('prompt_vars', {})
    end

    # The `` `severity_scale` `` config section mapping severity levels to human-readable labels.
    #
    # @return [Hash] severity level => label
    def severity_scale
      @data.fetch('severity_scale', {})
    end

    # The `` `confidence_scale` `` config section mapping confidence levels to human-readable labels.
    #
    # @return [Hash] confidence level => label
    def confidence_scale
      @data.fetch('confidence_scale', {})
    end

    # The "show" line: thresholds from `` `[post_process]` `` controlling whether a
    # finding is surfaced to maintainers at all. Absent/invalid values mean "no limit".
    #
    # @return [Hash] `{ max_severity:, max_confidence: }`, either possibly nil
    def show_threshold
      settings = @data.fetch('post_process', {})
      {
        max_severity: Threshold.parse(settings['max_severity']),
        max_confidence: Threshold.parse(settings['max_confidence'])
      }
    end

    # The "block" line: the threshold from `` `[approve]` `` controlling whether a
    # finding prevents auto-approval. `enabled` reflects whether auto-approval is
    # configured at all; when it isn't, the threshold is not meaningfully in effect.
    #
    # @return [Hash] `{ max_severity:, enabled: }`
    def block_threshold
      settings = @data.fetch('approve', {})
      { max_severity: Threshold.parse(settings['max_severity']), enabled: settings.fetch('enabled', false) }
    end

    # Absolute paths of the directories to scan for skill markdown fragments, defaulting to
    # `.agents`, `.claude`, and `.cursor` resolved against the project root.
    #
    # @return [Array<String>] absolute directory paths
    def skill_directories
      # expand_path leaves absolute paths intact and resolves relative ones
      # against the project root.
      Array(@data.fetch('skill_directories', DEFAULT_SKILL_DIRECTORIES)).map { |d| File.expand_path(d, @root) }
    end

    # All skill fragments discovered under {#skill_directories}, lazily loaded and memoized.
    #
    # @return [Array<Thingie::SkillFragment>] discovered skill fragments
    def skills
      @skills ||= skill_directories.flat_map { |dir| load_skills_from(dir) }
    end

    private

    def build_data
      load_user_env_file
      defaults = load_toml(default_config_path)
      project = project_config_path ? load_toml(project_config_path) : {}

      apply_env_overrides(deep_merge(defaults, project)).merge(@overrides)
    end

    def load_user_env_file
      # File.expand_path('~/...') raises ArgumentError when HOME is unresolvable
      # (e.g. some containers); a missing user env file is not fatal.
      path = File.expand_path(USER_ENV_FILE)
      return unless File.file?(path)

      # overwrite: true stops Dotenv::Parser from substituting real ENV values
      # for keys it already finds set — precedence between layers 3 and 4 is
      # ours to decide, via Env[key] ||= value below, not Dotenv's.
      Dotenv.parse(path, overwrite: true).each { |key, value| Env[key] ||= value }
    rescue StandardError
      # A missing/unreadable/malformed user env file must never be fatal.
      nil
    end

    def default_config_path
      File.expand_path('config/default.toml', __dir__)
    end

    def project_config_path
      path = File.join(@root, '.thingie', 'config.toml')
      File.file?(path) ? path : nil
    end

    def load_toml(path)
      Tomlrb.load_file(path, symbolize_keys: false)
    rescue StandardError => e
      raise "Failed to load config from #{path}: #{e.message}"
    end

    def deep_merge(base, override)
      base.each_with_object({}) do |(key, value), merged|
        merged[key] = merge_values(value, override[key])
      end.merge(override.slice(*override.keys - base.keys))
    end

    def merge_values(base_value, override_value)
      if base_value.is_a?(Hash) && override_value.is_a?(Hash)
        deep_merge(base_value, override_value)
      else
        override_value.nil? ? base_value : override_value
      end
    end

    def apply_env_overrides(config)
      config.merge(string_env_overrides).merge(integer_env_overrides)
    end

    def string_env_overrides
      ENV_OVERRIDES.transform_values do |env_key|
        Env.fetch(env_key, nil)
      end.compact
    end

    def integer_env_overrides
      # Only override keys that have a non-blank env var set; otherwise leave the
      # merged config value untouched (a blank var must not coerce to 0).
      INTEGER_ENV_OVERRIDES.each_with_object({}) do |(key, env_key), result|
        value = Env.fetch(env_key, nil)
        result[key] = value.to_i if value && !value.strip.empty?
      end
    end

    def load_skills_from(dir)
      return [] unless Dir.exist?(dir)

      # Use base: so the directory name is taken literally — glob metacharacters
      # in the path (e.g. brackets) don't change which files are matched.
      Dir.glob('**/*.md', base: dir).map do |relative|
        path = File.join(dir, relative)
        SkillFragment.new(path: path, content: File.read(path), source: dir)
      end
    end
  end

  # A single skill prompt fragment discovered from .agents, .claude, or .cursor.
  class SkillFragment
    attr_reader :path, :content, :source

    # Builds a fragment from an already-read skill file.
    #
    # @param path [String] absolute path to the skill's markdown file
    # @param content [String] the raw markdown content of the skill file
    # @param source [String] the skill directory this fragment was discovered under
    def initialize(path:, content:, source:)
      @path = path
      @content = content
      @source = source
    end

    # The skill's name, derived from its filename without the `.md` extension.
    #
    # @return [String] skill name
    def name
      File.basename(@path, '.md')
    end

    # One-line summary used as progressive-disclosure metadata (SkillCatalog),
    # so the LLM sees this instead of the full skill body until it asks for it.
    def description
      line = content.each_line.map(&:strip).find { |l| !l.empty? } || name
      line = line.sub(/\A#+\s*/, '')
      line.length > 150 ? "#{line[0, 150].rstrip}…" : line
    end
  end
end
