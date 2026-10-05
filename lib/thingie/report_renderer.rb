# frozen_string_literal: true

require 'json'

module Thingie
  # Renders a Thingie::Report to Markdown or CLI formats.
  class ReportRenderer
    # Fallback labels used when no severity scale is supplied (e.g. when
    # rendering a saved report via `thingie report` without config context).
    DEFAULT_SEVERITY_SCALE = {
      1 => 'Critical',
      2 => 'High',
      3 => 'Medium',
      4 => 'Low'
    }.freeze

    # Builds a renderer for the given report.
    #
    # @param report [Thingie::Report] the report to render
    # @param severity_scale [Hash, nil] severity level => label; falls back to {DEFAULT_SEVERITY_SCALE}
    def initialize(report, severity_scale: nil)
      @report = report
      @severity_scale = normalize_scale(severity_scale) || DEFAULT_SEVERITY_SCALE
    end

    # Render the report as colored plain text for the terminal.
    #
    # @return [String] CLI-formatted report
    def to_cli
      output = summary_line
      output += "#{source_line}\n"
      output += @report.issues.map { |issue| render_issue(issue) }.join
      output
    end

    # Render the report as Markdown, suitable for posting as a PR comment.
    #
    # @return [String] Markdown-formatted report
    def to_md
      lines = [Thingie::GitHub::Context::SUMMARY_MARKER, "#{md_summary_line}\n_#{source_line}_"]
      lines += @report.issues.map { |issue| md_issue(issue) }
      lines << md_details
      lines.compact.join("\n\n")
    end

    # Says which review ran so a reader can tell a deep run from the default;
    # the summary and each inline comment carry it.
    #
    # @return [String] e.g. "Reviewed with Claude Code `/code-review` (model)"
    def source_line
      details = @report.details || {}
      if details['source'] == ClaudeCodeSource::SOURCE_NAME
        "Reviewed with Claude Code `#{details['skill']}` (#{@report.model})"
      else
        "Reviewed with #{@report.model}"
      end
    end

    private

    # Run metadata, collapsed: what ran, how long, what it cost, and for a
    # Claude Code run its own written review, for "why did it say this?". The
    # notes are model text steered by the PR, so they go in a fence: no
    # @mentions, links or markup reach the reader as if Thingie wrote them.
    def md_details
      details = @report.details || {}
      return nil if details.empty?

      rows = details.except('notes').map { |key, value| "- **#{key}:** #{value}" }
      notes = details['notes'].to_s.strip
      body = rows.join("\n")
      body += "\n\n**Reviewer notes**\n\n~~~~text\n#{notes.gsub('~~~~', '~~~')}\n~~~~" unless notes.empty?
      "<details><summary>Review details</summary>\n\n#{body}\n\n</details>"
    end

    def summary_line
      if @report.total_issues.positive?
        "⚠️  #{@report.total_issues} issue(s) found across " \
          "#{@report.number_of_processed_files} file(s).\n"
      else
        "✅ No issues found across #{@report.number_of_processed_files} file(s).\n"
      end
    end

    def md_summary_line
      if @report.total_issues.positive?
        "**⚠️ #{@report.total_issues} issue(s) found** across " \
          "#{@report.number_of_processed_files} file(s)."
      else
        "**✅ No issues found** across #{@report.number_of_processed_files} file(s)."
      end
    end

    def render_issue(issue)
      location = first_location(issue)
      heading = "## [#{issue.id}] #{issue.title}"
      heading += " [#{severity_label(issue.severity)}]" if issue.severity
      heading += "\n  #{issue.file}"
      heading += ":#{location}" if location
      details = "  #{issue.details}" if issue.details
      "#{[heading, details].compact.join("\n")}\n"
    end

    def md_issue(issue)
      location = first_location(issue)
      link = location ? "[#{issue.file}:#{location}](#{issue.file}##{location})" : issue.file
      lines = ["## ##{issue.id} #{md_title(issue)}", link, issue.details]
      lines << "**Tags:** #{issue.tags.join(', ')}" unless issue.tags.to_a.empty?
      lines.compact.join("\n\n")
    end

    def md_title(issue)
      return issue.title unless issue.severity

      "#{issue.title} **[#{severity_label(issue.severity)}]**"
    end

    def severity_label(severity)
      @severity_scale[severity.to_i] || "L#{severity}"
    end

    def first_location(issue)
      line = issue.affected_lines&.first
      return unless line&.start_line

      if line.end_line && line.end_line != line.start_line
        "L#{line.start_line}-L#{line.end_line}"
      else
        "L#{line.start_line}"
      end
    end

    # Accept either string-keyed (from TOML) or integer-keyed scales and return
    # a lookup keyed by integer severity. Returns nil if no scale was supplied.
    def normalize_scale(scale)
      return nil if scale.nil? || scale.empty?

      scale.each_with_object({}) do |(key, label), map|
        map[key.to_s.to_i] = label
      end
    end
  end
end
