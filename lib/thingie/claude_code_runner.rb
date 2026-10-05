# frozen_string_literal: true

require 'open3'

module Thingie
  # Runs the Claude Code CLI as a child process for {ClaudeCodeSource}: a
  # trimmed environment, the prompt on stdin, and a real timeout, which
  # `Open3.capture3` does not offer.
  module ClaudeCodeRunner
    # The child only gets what the CLI needs to run and authenticate. Thingie's
    # own LLM key and the workflow's tokens stay out of the run, so a prompt
    # injected through the PR cannot read them back out of the environment.
    ENV_KEYS = %w[PATH HOME TMPDIR LANG LC_ALL TERM NO_COLOR].freeze
    ENV_PREFIXES = %w[ANTHROPIC_ CLAUDE_].freeze

    module_function

    # Run `argv` in `chdir` with `stdin` as its input, killing it (TERM, then
    # KILL) when `timeout` seconds pass. Output is drained on threads so a
    # chatty run cannot block on a full pipe.
    #
    # @param argv [Array<String>] command and arguments
    # @param chdir [String] working directory for the command
    # @param stdin [String] text written to the command's stdin
    # @param timeout [Numeric] seconds to wait before killing the command
    # @return [Array(String, String, Process::Status)] stdout, stderr and exit status
    # @raise [RuntimeError] when the command exceeds `timeout`
    def call(argv, chdir:, stdin:, timeout:)
      Open3.popen3(env, *argv, chdir: chdir, unsetenv_others: true) do |in_io, out_io, err_io, wait|
        out = Thread.new { out_io.read }
        err = Thread.new { err_io.read }
        in_io.write(stdin)
        in_io.close
        unless wait.join(timeout)
          ::Process.kill('TERM', wait.pid)
          ::Process.kill('KILL', wait.pid) unless wait.join(10)
          raise "#{argv.first} timed out after #{timeout}s"
        end
        [out.value, err.value, wait.value]
      end
    end

    # The environment handed to the child, and the one whose secret values
    # must not come back in its output.
    #
    # @return [Hash{String=>String}] the allowed subset of the current environment
    def env
      Env.store.to_h.select do |key, _|
        ENV_KEYS.include?(key) || ENV_PREFIXES.any? { |prefix| key.start_with?(prefix) }
      end
    end

    # The CLI's own output is the one channel back to the PR, so refuse to use
    # output that echoes a credential from its environment.
    #
    # @param text [String] the CLI's stdout
    # @param command [String] the command name, for the error
    # @return [void]
    # @raise [RuntimeError] when a credential value appears in `text`
    def reject_leaked_secrets!(text, command)
      leaked = leaked_secrets(text)
      raise "#{command} output contains the value of #{leaked.join(', ')}; refusing to use it" if leaked.any?
    end

    # The names of credential variables in {.env} (`*_KEY`, `*_TOKEN`) whose
    # values appear in `text`. Other forwarded variables, such as the default
    # model names, are expected to show up in the result.
    #
    # @param text [String] output to check
    # @return [Array<String>] variable names found verbatim in `text`
    def leaked_secrets(text)
      env.select do |key, value|
        key.end_with?('_KEY', '_TOKEN') && value.to_s.length >= 16 && text.include?(value)
      end.keys
    end
  end
end
