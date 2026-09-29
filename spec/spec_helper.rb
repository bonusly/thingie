# frozen_string_literal: true

require 'thingie'
require 'tmpdir'
require_relative 'support/llm_doubles'

# Default set of environment variables for specs. Empty by default so a
# developer's real shell exports (LLM_API_KEY, VERIFY_MODEL, etc.) can never
# leak into test behavior — tests that need a variable set it explicitly via
# Thingie::Env['KEY'] = 'value' or Thingie::Env.store.merge!(...).
DEFAULT_TEST_ENV = {}.freeze

# A ~/.thingie/.env that doesn't exist, so Configuration#load_user_env_file
# never reads a developer's real user-level env file into a spec.
NO_SUCH_USER_ENV_FILE = File.join(Dir.tmpdir, 'thingie-spec-no-such.env')

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Isolate every example from the real process environment and from
  # ~/.thingie/.env: Configuration#load_user_env_file only ever touches
  # Thingie::Env (a throwaway Hash here, not ENV), and reads from a path that
  # never exists. Specs that need to exercise the real file explicitly
  # stub_const USER_ENV_FILE again in their own before block.
  config.before do
    Thingie::Env.store = DEFAULT_TEST_ENV.dup
    stub_const('Thingie::Configuration::USER_ENV_FILE', NO_SUCH_USER_ENV_FILE)
  end
end
