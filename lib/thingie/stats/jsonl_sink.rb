# frozen_string_literal: true

require 'json'
require 'fileutils'

module Thingie
  module Stats
    # Built-in sink that appends one JSON object per event to a file, or to
    # stdout/stderr. Registered under the `"jsonl"` sink type.
    class JsonlSink
      # Builds a JSON-lines sink from its `[[stats.sinks]]` config entry.
      #
      # @param config [Hash] the sink's TOML hash (string keys); requires a
      #   non-blank `path` (`"stdout"` / `"stderr"` select the matching stream,
      #   anything else is a file path resolved against `root`)
      # @param root [String] project root for resolving relative file paths
      def initialize(config:, root:)
        path = config['path']
        raise ArgumentError, 'jsonl sink requires a non-blank "path"' if path.nil? || path.to_s.strip.empty?

        @root = root
        @stream_name, @expanded = resolve_path(path)
      end

      # Writes one JSON object, followed by a newline, to the configured
      # stream/file. Per-write open/close for file sinks — both `review` and
      # `github-comment` are short-lived processes, so no handle is kept open.
      #
      # @param event [Hash] fully-formed, string-keyed event Hash
      # @return [void]
      def emit(event)
        line = JSON.generate(event)
        if @stream_name
          stream.puts(line)
        else
          File.open(@expanded, 'a') { |f| f.puts(line) }
        end
      end

      private

      # Returns the live IO stream for a `stdout`/`stderr` sink. Resolved on
      # each emit so `$stdout`/`$stderr` redirects (e.g. test capture) are
      # honored even when the sink was constructed before the redirect.
      #
      # @return [IO] the stream to write to
      def stream
        @stream_name == 'stdout' ? $stdout : $stderr
      end

      # Resolves `path` into either a stream name (`"stdout"`/`"stderr"`) or an
      # expanded absolute file path, creating parent directories for the latter.
      #
      # @param path [String] the configured path value
      # @return [Array(String, nil), Array(nil, String)] the stream name (or
      #   nil for file sinks) and the expanded file path (or nil for streams)
      def resolve_path(path)
        case path
        when 'stdout' then ['stdout', nil]
        when 'stderr' then ['stderr', nil]
        else
          expanded = File.expand_path(path, @root)
          FileUtils.mkdir_p(File.dirname(expanded))
          [nil, expanded]
        end
      end
    end
  end
end
