# frozen_string_literal: true

module Thingie
  # Parses a JSON array of LLM issues into Thingie domain objects.
  class IssueParser
    # Parse a JSON array (or single object) of raw LLM issue hashes into `Thingie::Issue` objects.
    #
    # @param issues [Array<Hash>, Hash, nil] raw issue hashes from the LLM response
    # @param file [String] the repo-relative path the issues belong to
    # @return [Array<Thingie::Issue>] parsed issues
    def parse(issues, file)
      wrap(issues).map { |issue| raw_issue(issue).then { |raw| build_issue(raw, file) } }
    end

    private

    # Like Array(), but treats a lone Hash as a single element rather than
    # exploding it into [key, value] pairs.
    def wrap(value)
      return [] if value.nil?

      value.is_a?(Array) ? value : [value]
    end

    def raw_issue(issue)
      RawIssue.new(
        title: issue.fetch('title'),
        severity: issue.fetch('severity'),
        confidence: issue.fetch('confidence'),
        details: issue['details'],
        tags: issue['tags'] || [],
        affected_lines: parse_affected_lines(issue['affected_lines']),
        evidence: issue['evidence']
      )
    end

    def build_issue(raw, file)
      Issue.new(
        id: nil,
        file: file,
        raw_issue: raw,
        affected_lines: raw.affected_lines
      )
    end

    def parse_affected_lines(lines)
      wrap(lines).map do |line|
        AffectedRange.new(
          start_line: line['start_line'],
          end_line: line['end_line'] || line['start_line'],
          proposal: line['proposal'],
          affected_code: line['affected_code']
        )
      end
    end
  end
end
