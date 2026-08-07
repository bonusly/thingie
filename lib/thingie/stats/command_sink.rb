# frozen_string_literal: true

require 'json'

module Thingie
  module Stats
    # Built-in sink that pipes one JSON line per event to an external command's
    # stdin. Registered under the `"command"` sink type. On any failure (bad
    # command, dead pipe) it warns once, disables itself, and silently no-ops
    # on subsequent emits — never raising into the pipeline.
    class CommandSink
      # Builds a command sink from its `[[stats.sinks]]` config entry.
      #
      # @param config [Hash] the sink's TOML hash (string keys); requires a
      #   non-blank `command`
      # @param root [String] project root (kept for a uniform sink contract)
      def initialize(config:, root:)
        command = config['command']
        raise ArgumentError, 'command sink requires a non-blank "command"' if command.nil? || command.to_s.strip.empty?

        @command = command
        @root = root
        @io = nil
        @dead = false
      end

      # Writes one JSON object + newline to the command's stdin, opening the
      # pipe lazily on the first emit. Once disabled, emits are silent no-ops.
      #
      # @param event [Hash] fully-formed, string-keyed event Hash
      # @return [void]
      def emit(event)
        return if @dead

        @io ||= IO.popen(@command, 'w')
        @io.puts(JSON.generate(event))
        @io.flush
      rescue StandardError => e
        warn "Stats command sink '#{@command}' failed — disabling: #{e.message}"
        @dead = true
      end
    end
  end
end
