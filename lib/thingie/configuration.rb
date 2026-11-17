# frozen_string_literal: true

require 'tomlrb'
require 'dotenv'

module Thingie
  # Loads and merges Thingie configuration.
  #
  # Layers (later layers override earlier ones):
  # 1. Bundled defaults from lib/thingie/config/default.toml
  # 2. Project-specific .thingie/config.toml
  # 3. Explicit overrides passed to Configuration.new
  #
  # ~/.thingie/.env is also loaded into the environment (without replacing
  # variables already set), so local runs can keep their tokens there.
  class Configuration
    attr_reader :data, :root

    # Expanded lazily in load_user_env_file so a missing/unresolvable home
    # directory can't crash at load time.
    USER_ENV_FILE = '~/.thingie/.env'

    # Build the merged configuration for a project by loading and combining all layers.
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
    # @param key [String, Symbol] config key, e.g. `` `approve` ``
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

    private

    def build_data
      load_user_env_file
      defaults = load_toml(default_config_path)
      project = project_config_path ? load_toml(project_config_path) : {}

      deep_merge(defaults, project).merge(@overrides)
    end

    def load_user_env_file
      # File.expand_path('~/...') raises ArgumentError when HOME is unresolvable
      # (e.g. some containers); a missing user env file is not fatal.
      path = File.expand_path(USER_ENV_FILE)
      return unless File.file?(path)

      # overwrite: true stops Dotenv::Parser from substituting real ENV values
      # for keys it already finds set — whether the OS environment wins is ours
      # to decide, via Env[key] ||= value below, not Dotenv's.
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
  end
end
