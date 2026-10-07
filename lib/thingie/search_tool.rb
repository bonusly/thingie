# frozen_string_literal: true

require 'open3'
require 'timeout'
require 'ruby_llm'
require_relative 'llm_compat'

module Thingie
  # RubyLLM tool that lets the model search the reviewed repository with
  # `git grep`: find where a method is called, whether a guard exists, how a
  # constant is used. Read-only, runs without a shell, and is limited to tracked
  # files under the working directory, so a finding can be checked against the
  # code instead of guessed at.
  class SearchTool < RubyLLM::Tool
    MAX_MATCHES = 60
    MAX_LINE = 240
    MAX_PATTERN = 200
    TIMEOUT = 15
    READ_CHUNK = 4096

    description <<~DESC
      Search the repository's tracked files with a regular expression (git grep -E)
      and return matching lines as `path:line:text`. Use it to confirm a suspicion
      before you report it: find callers of a changed method, check whether a guard
      or validation exists elsewhere, see how a constant or column is used. Optionally
      limit the search to a path inside the repository.
    DESC

    LlmCompat.parameter(self, :pattern, description: 'Extended regular expression to search for', required: true)
    LlmCompat.parameter(self, :path, description: 'Directory or file to limit the search to, relative to the ' \
                                                  'repository root (optional)', required: false)
    LlmCompat.parameter(self, :ignore_case, description: 'Match case-insensitively (optional, default false)',
                                            required: false)

    # Builds a search tool bound to the repository at `root`.
    #
    # @param root [String] path to the repository working directory searches run in
    def initialize(root:)
      super()
      @root = File.realpath(root)
    end

    # Runs the search and returns a human-readable result.
    #
    # @param pattern [String] extended regular expression to search for
    # @param path [String, nil] directory or file, relative to the root, to limit the search to
    # @param ignore_case [Boolean, nil] match case-insensitively
    # @return [String] matching lines, or a status message when nothing matched or the search was refused
    def execute(pattern:, path: nil, ignore_case: false)
      return 'Pattern is empty.' if pattern.to_s.strip.empty?
      return "Pattern is longer than #{MAX_PATTERN} characters." if pattern.length > MAX_PATTERN
      return "Path `#{path}` is outside the repository." unless inside?(path)

      format_result(pattern, run(pattern, path, ignore_case))
    rescue Timeout::Error
      "Search for `#{pattern}` timed out; narrow it with a path."
    rescue StandardError => e
      "Search unavailable: #{e.message}"
    end

    private

    def inside?(path)
      return true if path.to_s.strip.empty?

      resolved = File.expand_path(path, @root)
      resolved == @root || resolved.start_with?("#{@root}#{File::SEPARATOR}")
    end

    def run(pattern, path, ignore_case)
      # --literal-pathspecs makes `path` a plain path. Otherwise the tool reads pathspec magic such as
      # `:(exclude)app` in it, and the search is no longer limited to what was asked for.
      argv = ['git', '-C', @root, '--literal-pathspecs', 'grep', '-n', '-I', '--no-color', '-E']
      argv << '-i' if ignore_case == true || ignore_case.to_s == 'true'
      argv.push('-e', pattern)
      argv.push('--', path.to_s) unless path.to_s.strip.empty?
      Timeout.timeout(TIMEOUT) { stream(argv) }
    end

    # Reads only as many lines as are shown, plus one to know there are more, and then stops the search. A
    # broad pattern in a large repository would otherwise be buffered whole before the cap applied. Reading
    # in bounded chunks also keeps one very long line from filling memory.
    def stream(argv)
      lines = []
      Open3.popen3(*argv) do |stdin, stdout, stderr, waiter|
        stdin.close
        errors = Thread.new { stderr.read.to_s }
        finished = false
        begin
          stdout.each_line(READ_CHUNK) do |line|
            lines << line
            break if lines.size > MAX_MATCHES
          end
          finished = lines.size <= MAX_MATCHES
        ensure
          stop(waiter) unless finished
        end
        [lines, errors.value, waiter.value]
      end
    end

    def stop(waiter)
      Process.kill('TERM', waiter.pid) if waiter.alive?
    rescue Errno::ESRCH
      nil
    end

    def format_result(pattern, (lines, stderr, status))
      return "Search for `#{pattern}` failed: #{stderr.to_s.strip[0, 200]}" if status.exitstatus.to_i > 1
      return "No matches for `#{pattern}`." if lines.empty?

      shown = lines.first(MAX_MATCHES).map { |line| line.chomp[0, MAX_LINE] }
      shown << '... more matches not shown; narrow the pattern or path.' if lines.size > MAX_MATCHES
      shown.join("\n")
    end
  end
end
