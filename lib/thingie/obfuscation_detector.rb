# frozen_string_literal: true

module Thingie
  # Scans the full content of every changed file for common code-obfuscation
  # techniques (encoded blobs, any eval-family call, indirect eval invocation,
  # character-code string construction, dense escape runs). Any finding is a
  # hard block on auto-approval: encoded or dynamically-constructed code always
  # gets human review.
  #
  # Signals naming a real code construct are skipped on lines that are wholly
  # comments, because documentation quotes example code constantly ("a SCORED
  # eval (LLM judge)", "`[65, 66].pack('C*')`") and a comment cannot execute.
  # Only whole-line comments are exempt, never the tail of a line that also
  # holds code, so no line is ever scanned in part. Blob and escape-run
  # signals scan every line: prose never contains 80 hex characters or ten
  # consecutive unicode escapes by accident.
  #
  # Deliberately pattern-based rather than LLM-based: obfuscation signals are
  # lexical, the check must run on every changed file every time, and a
  # heuristic that can't hallucinate can't be argued away.
  class ObfuscationDetector
    # One flagged line.
    Finding = Struct.new(:file, :line_number, :description, :snippet, keyword_init: true)

    # Cap per file so a heavily obfuscated file doesn't flood the status
    # comment; one match already blocks approval.
    MAX_MATCHES_PER_FILE = 5

    # 80+ contiguous hex chars — packed binaries, shellcode, hex-encoded payloads.
    HEX_BLOB = /\h{80,}/
    # 100+ contiguous base64 chars — encoded payloads, not prose (which has spaces).
    BASE64_BLOB = %r{[A-Za-z0-9+/]{100,}={0,2}}
    # Eval family — direct or indirect invocation. ANY eval call blocks: composed
    # obfuscation (decode on one line, eval on the next) evades same-line
    # heuristics, so whether a given eval is benign is a human reviewer's call.
    EVAL_CALL = /
      \b(?:eval|instance_eval|class_eval|module_eval)\b\s*\(
      |\b(?:send|public_send|__send__)\s*\(\s*['":]eval\b
      |\bmethod\s*\(\s*['":]eval\b
    /x
    # JavaScript `String.fromCharCode(72, 101, ...)` with two or more codes.
    FROM_CHAR_CODE = /String\.fromCharCode\s*\(\s*\d+\s*,/
    # Ruby byte-array-to-string construction: `[65, 66].pack('C*')` (and the
    # lowercase/unicode pack directives).
    PACK_C_STAR = /pack\s*\(\s*['"][CcUu]\*['"]/
    # Repeated Ruby character-code literals: `104.chr + 101.chr + ...`.
    CHAR_LITERAL = /\d+\s*\.\s*chr\b/
    # Dense escape runs: `...\x41\x42...` (8+) or `...\u0041\u0042...` (10+).
    ESCAPE_RUN = /(?:\\x\h{2}){8,}|(?:\\u\h{4}){10,}/i
    # A line holding nothing but a comment: Ruby `#` or C-family `//`.
    COMMENT_LINE = %r{\A\s*(?:#|//)}

    # Builds a detector over already-read file contents.
    #
    # @param files [Hash{String => String, nil}] path => full file content; nil for a binary or deleted file
    def initialize(files)
      @files = files
    end

    # Scans the full content of every file and returns one finding per matched
    # line (up to {MAX_MATCHES_PER_FILE} per file). The whole file is scanned,
    # not just added lines: a changed file that includes obfuscated code blocks
    # approval whether or not the obfuscation was added by this PR. Files with
    # nil content are skipped.
    #
    # @return [Array<Finding>] a finding for each detected signal
    def call
      @files.flat_map { |file, content| findings_for(file, content) }
    end

    private

    def findings_for(file, content)
      return [] if content.nil?

      matches = []
      content.each_line.with_index(1) do |line, number|
        break if matches.size >= MAX_MATCHES_PER_FILE

        description = describe(line)
        next if description.nil?

        matches << Finding.new(file: file, line_number: number, description: description, snippet: snippet(line))
      end
      matches
    end

    # First matching signal wins, so one line yields at most one issue (a hex
    # blob also matches the base64 pattern; hex is checked first as the more
    # specific signal).
    #
    # @param line [String] a single line of source
    # @return [String, nil] human-readable signal description, or nil
    def describe(line)
      return 'a long hex-encoded blob' if line.match?(HEX_BLOB)
      return 'a long base64-encoded blob' if line.match?(BASE64_BLOB)

      unless comment_line?(line)
        return 'dynamic code execution (eval)' if line.match?(EVAL_CALL)
        return 'an executable string built from character codes' if char_code_construction?(line)
      end

      'a dense run of escape sequences' if line.match?(ESCAPE_RUN)
    end

    # Whether the whole line is a comment. Only a line that is nothing but a
    # comment is exempted, never the tail of a line that also holds code: a
    # comment marker is exempted only where nothing on the line can execute.
    #
    # Splitting a line at its first `#` or `//` instead would need a real
    # lexer to be safe. A marker inside a regex, percent literal or template
    # literal (`%r{^https?://}`, `s =~ %r{#frag}`, a JS `${}` template) is not
    # a comment, and truncating there would hide any obfuscation later on the
    # same line. For a rule that hard-blocks, a missed signal is the worse
    # error, so the trailing-comment case keeps its (rare) false positive.
    #
    # Block-comment interiors (`=begin`, `/* ... */`) are not tracked; example
    # code quoted inside one still matches.
    #
    # @param line [String] a single line of source
    # @return [Boolean] whether the line is entirely a comment
    def comment_line?(line)
      line.match?(COMMENT_LINE)
    end

    # @param line [String] a single line of source
    # @return [Boolean] whether the line builds a string from character codes
    def char_code_construction?(line)
      line.match?(FROM_CHAR_CODE) ||
        line.match?(PACK_C_STAR) ||
        line.scan(CHAR_LITERAL).size >= 3
    end

    # @param line [String] the matched source line
    # @return [String] the line, stripped and truncated for display
    def snippet(line)
      line.strip[0, 120]
    end
  end
end
