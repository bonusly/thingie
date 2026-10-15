# frozen_string_literal: true

require 'ruby_llm'
require_relative 'llm_compat'

module Thingie
  # RubyLLM tool that lets the model check whether a path relative to the working
  # directory exists, and read its contents when it is a non-binary file. Paths
  # are constrained to stay within the working directory: any attempt to escape
  # it (via `..`, absolute paths, or symlinks pointing outside) is rejected.
  class FileTool < RubyLLM::Tool
    # Number of leading bytes inspected to decide whether a file is binary. A
    # NUL byte anywhere in this window, or a UTF-8 decoding failure, marks the
    # file as binary so we never dump non-textual bytes into the model context.
    SNIFF_BYTES = 8192
    # A read stops at whichever of these comes first, so one generated or
    # vendored file (a 2.7 MB JSON fixture, say) cannot fill the model's context.
    MAX_LINES = 2000
    MAX_BYTES = 100_000
    SEARCH_HINT = 'Use the search tool with this path to find the lines you need further down.'

    description <<~DESC
      Check whether a path relative to the working directory exists, and read its
      contents when it is a non-binary file. Paths cannot escape the working
      directory: `..`, absolute paths, and symlinks pointing outside it are
      rejected. Use this to inspect existing files for context during a review.
    DESC

    LlmCompat.parameter(self, :path, description: 'Path relative to the working directory to inspect', required: true)

    # Builds a file tool constrained to reads under `root`.
    #
    # @param root [String] path to the working directory reads are constrained to
    def initialize(root:)
      super()
      # Canonicalize the root so symlinked prefixes (e.g. /tmp -> /private/tmp
      # on macOS) match the realpath'd candidates compared against it.
      @root = File.realpath(root)
    end

    # Checks whether `path` exists relative to the working directory, and returns its
    # contents when it is a non-binary, readable file.
    #
    # @param path [String] path relative to the working directory
    # @return [String] a human-readable result: file contents, or a status message
    def execute(path:)
      resolved = resolve(path)
      return "Path `#{path}` is outside the working directory." if resolved.nil?
      return "Path `#{relative(resolved)}` does not exist." unless File.exist?(resolved)

      return "Path `#{relative(resolved)}` is a directory." if File.directory?(resolved)

      return "Path `#{relative(resolved)}` is not readable." unless File.readable?(resolved)

      return binary_message(resolved) if binary?(resolved)

      contents, note = read_capped(resolved)
      result = "#{relative(resolved)}\n```\n#{contents}\n```"
      note ? "#{result}\n#{note}" : result
    rescue StandardError => e
      "File lookup unavailable for `#{path}`: #{e.message}"
    end

    private

    # Expand `path` relative to the working directory, collapse every symlink in
    # the resulting path with `File.realpath`, and confirm the fully-resolved
    # target still sits inside the working directory. Resolving the whole path
    # (not just the final component) closes a traversal gap where a symlinked
    # intermediate directory points outside the root, and using the resolved path
    # for all subsequent reads avoids a Time-of-Check to Time-of-Use race.
    def resolve(path)
      candidate = File.expand_path(path, @root)
      resolved = realpath(candidate)
      return nil unless resolved

      inside?(resolved) ? resolved : nil
    end

    # `File.realpath` raises ENOENT for a non-existent path component, so walk up
    # the tree until an existing ancestor is resolved, then reappend the missing
    # tail components. Recursion (rather than a single `realpath(parent)` call)
    # handles paths where several intermediate directories don't exist yet; an
    # exception raised inside a rescue block isn't caught by sibling rescue
    # clauses, so a non-recursive call would escape as an unhelpful error.
    def realpath(candidate)
      File.realpath(candidate)
    rescue Errno::ENOENT
      parent = File.dirname(candidate)
      return candidate if parent == candidate # reached filesystem root

      File.join(realpath(parent), File.basename(candidate))
    rescue StandardError
      nil
    end

    def inside?(path)
      path == @root || path.start_with?("#{@root}#{File::SEPARATOR}")
    end

    # Treat a file as binary when its leading bytes contain a NUL byte or fail to
    # decode as UTF-8, mirroring the heuristic git uses for text/binary detection.
    def binary?(path)
      head = File.binread(path, SNIFF_BYTES) || ''
      return true if head.include?("\0")

      head.force_encoding('UTF-8')
      !head.valid_encoding?
    rescue StandardError
      true
    end

    # Returns the file's leading lines up to MAX_LINES / MAX_BYTES, and a note
    # saying what was left out (nil when the whole file fit).
    def read_capped(path)
      kept = []
      bytes = 0
      total = 0
      stopped = false
      File.foreach(path) do |line|
        total += 1
        stopped ||= kept.size >= MAX_LINES || bytes + line.bytesize > MAX_BYTES
        next if stopped

        kept << line
        bytes += line.bytesize
      end
      return [kept.join, nil] unless stopped
      return [kept.join, "Truncated: showing lines 1-#{kept.size} of #{total}. #{SEARCH_HINT}"] if kept.any?

      head = File.foreach(path).first.byteslice(0, MAX_BYTES).scrub('')
      [head, "Truncated: line 1 is longer than #{MAX_BYTES} bytes; showing its start. #{SEARCH_HINT}"]
    end

    def binary_message(path)
      "Path `#{relative(path)}` exists but is a binary file; contents are not available."
    end

    def relative(path)
      path.start_with?("#{@root}#{File::SEPARATOR}") ? path.delete_prefix("#{@root}#{File::SEPARATOR}") : path
    end
  end
end
