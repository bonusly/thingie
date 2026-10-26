# frozen_string_literal: true

module Thingie
  # Raised when required configuration is missing or invalid.
  class ConfigurationError < StandardError
  end

  # Raised when a language server fails to start or respond.
  class LspError < StandardError
  end

  # Raised when a System One provider returns an error or an unexpected response.
  class SystemOneError < StandardError
  end

  # Raised when an agent CLI (`claude -p`, `codex exec`) fails or answers without a result.
  class AgentCliError < StandardError
  end
end
