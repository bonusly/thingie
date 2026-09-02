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
      output += @report.issues.map { |issue| render_issue(issue) }.join
      output
    end

    # Render the report as Markdown, suitable for posting as a PR comment.
    #
    # @return [String] Markdown-formatted report
    def to_md
      lines = [Thingie::GitHub::Context::SUMMARY_MARKER, md_summary_line]
      lines += @report.issues.map { |issue| md_issue(issue) }
      lines.join("\n\n")
    end

    private

    def summary_line
      line = if @report.total_issues.positive?
               "⚠️  #{@report.total_issues} issue(s) found across #{coverage_file_count}.\n"
             else
               "✅ No issues found across #{coverage_file_count}.\n"
             end
      line + unreviewed_files_line
    end

    def md_summary_line
      line = if @report.total_issues.positive?
               "**⚠️ #{@report.total_issues} issue(s) found** across #{coverage_file_count}."
             else
               "**✅ No issues found** across #{coverage_file_count}."
             end
      line + md_unreviewed_files_line
    end

    # A bare "N issue(s)/No issues found across M file(s)" reads as a complete
    # pass over every file, whether or not any issues were found. When some of
    # those M were never reviewed, say so in the headline itself, not only in
    # the disclosure line beneath it, so the headline can't be mistaken for
    # full coverage on its own — number_of_processed_files is the whole
    # changeset (see Reviewer#build_report) and unreviewed_files is a subset
    # of it, in both the clean-pass and issues-found case alike.
    def coverage_file_count
      reviewed = @report.number_of_processed_files - @report.unreviewed_files.size
      return "#{@report.number_of_processed_files} file(s)" if @report.unreviewed_files.empty?

      "#{reviewed} of #{@report.number_of_processed_files} file(s)"
    end

    # A file with no findings and a file no verdict was ever produced for
    # look identical in `total_issues` alone — this is the only thing that
    # tells them apart in the human-facing summary. Without it, a run where a
    # file's LLM call failed or came back blank reads as a clean pass in both
    # the CLI output and the Markdown PR comment, even though the report
    # covers less than the full changeset.
    #
    # @return [String] a disclosure line, or "" when every file got a verdict
    def unreviewed_files_line
      return '' if @report.unreviewed_files.empty?

      "⚠️  #{@report.unreviewed_files.size} file(s) could not be reviewed: " \
        "#{@report.unreviewed_files.join(', ')}\n"
    end

    # @return [String] a disclosure line, or "" when every file got a verdict
    def md_unreviewed_files_line
      return '' if @report.unreviewed_files.empty?

      "\n\n**⚠️ #{@report.unreviewed_files.size} file(s) could not be reviewed:** " \
        "#{@report.unreviewed_files.join(', ')}"
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
