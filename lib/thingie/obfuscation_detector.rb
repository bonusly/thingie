# frozen_string_literal: true

module Thingie
  # Scans the full content of every changed file for common code-obfuscation
  # techniques (encoded blobs, dynamic code execution on encoded data,
  # character-code string construction, dense escape runs). Findings are
  # returned as severity-1 issues tagged `obfuscation`, which the auto-approval
  # rules treat as a hard block independent of the severity threshold.
  #
  # Deliberately pattern-based rather than LLM-based: obfuscation signals are
  # lexical, the check must run on every changed file every time (not at the
  # model's discretion), and a heuristic that can't hallucinate can't be
  # argued away by the critic pass either — Reviewer adds these issues after
  # the critic pass so thresholds and verification cannot suppress them.
  class ObfuscationDetector
    # Tags identifying scanner findings. The LLM's own findings never carry
    # `obfuscation` — the review schema's tag list is unrestricted, but the
    # Approver treats a finding with this tag as scanner-authoritative.
    TAGS = %w[security obfuscation].freeze

    # Cap per file so a heavily obfuscated file doesn't flood the PR with
    # inline comments; one match already blocks approval.
    MAX_MATCHES_PER_FILE = 5

    # 80+ contiguous hex chars — packed binaries, shellcode, hex-encoded payloads.
    HEX_BLOB = /\h{80,}/
    # 100+ contiguous base64 chars — encoded payloads, not prose (which has spaces).
    BASE64_BLOB = %r{[A-Za-z0-9+/]{100,}={0,2}}
    # Ruby eval family; `send`/`public_send` are excluded as ordinary metaprogramming.
    EVAL_CALL = /\b(?:eval|instance_eval|class_eval|module_eval)\b\s*\(/
    # Same-line markers that make an eval-family call suspicious: the argument
    # is decoded or constructed at runtime rather than a readable literal.
    DECODE_MARKER = /Base64|decode|unpack\b|pack\b|\.chr\b|\\x\h{2}|fromCharCode|\.reverse\b/
    # JavaScript `String.fromCharCode(72, 101, ...)` with two or more codes.
    FROM_CHAR_CODE = /String\.fromCharCode\s*\(\s*\d+\s*,/
    # Ruby byte-array-to-string construction: `[65, 66].pack('C*')`.
    PACK_C_STAR = /pack\s*\(\s*['"]C\*['"]/
    # Repeated Ruby character-code literals: `104.chr + 101.chr + ...`.
    CHAR_LITERAL = /\d+\s*\.\s*chr\b/
    # Dense escape runs: `...\x41\x42...` (8+) or `...\u0041\u0042...` (10+).
    ESCAPE_RUN = /(?:\\x\h{2}){8,}|(?:\\u\h{4}){10,}/i

    # Builds a detector for a changeset.
    #
    # @param changeset [Thingie::Changeset] the files under review
    def initialize(changeset)
      @changeset = changeset
    end

    # Scans the full content of every changed file and returns one severity-1
    # issue per matched line (up to {MAX_MATCHES_PER_FILE} per file). The whole
    # file is scanned, not just added lines: a changed file that includes
    # obfuscated code blocks approval whether or not the obfuscation was
    # added by this PR. Binary files (nil content) are skipped.
    #
    # @return [Array<Thingie::Issue>] issues for each detected signal
    def call
      @changeset.files.filter_map { |file| issues_for(file) }.flatten
    end

    private

    def issues_for(file)
      content = @changeset.full_content_for(file)
      return [] if content.nil?

      matches = []
      content.each_line.with_index(1) do |line, number|
        break if matches.size >= MAX_MATCHES_PER_FILE

        description = describe(line)
        next if description.nil?

        matches << build_issue(file: file, line_number: number, description: description, line: line)
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
      if line.match?(EVAL_CALL) && line.match?(DECODE_MARKER)
        return 'dynamic code execution on encoded or constructed data'
      end
      return 'an executable string built from character codes' if char_code_construction?(line)

      'a dense run of escape sequences' if line.match?(ESCAPE_RUN)
    end

    # @param line [String] a single line of source
    # @return [Boolean] whether the line builds a string from character codes
    def char_code_construction?(line)
      line.match?(FROM_CHAR_CODE) ||
        line.match?(PACK_C_STAR) ||
        line.scan(CHAR_LITERAL).size >= 3
    end

    def build_issue(file:, line_number:, description:, line:)
      Issue.new(
        id: nil,
        file: file,
        raw_issue: RawIssue.new(
          title: "Obfuscated code detected (#{description})",
          details: details_for(description, line_number, line),
          severity: 1,
          confidence: 1,
          tags: TAGS
        ),
        affected_lines: [AffectedRange.new(
          start_line: line_number,
          end_line: line_number,
          affected_code: snippet(line)
        )]
      )
    end

    def details_for(description, line_number, line)
      "Thingie's obfuscation scanner flagged #{description} on line #{line_number}. " \
        'Obfuscated code always requires human review and blocks auto-approval. ' \
        "Matched code: `#{snippet(line)}`"
    end

    # @param line [String] the matched source line
    # @return [String] the line, stripped and truncated for display
    def snippet(line)
      line.strip[0, 120]
    end
  end
end
