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
      lines = [Thingie::GitHub::Context::SUMMARY_MARKER, md_heading, md_summary_line,
               md_files_reviewed, md_run_info].compact
      lines += @report.issues.map { |issue| md_issue(issue) }
      lines.join("\n\n")
    end

    private

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
        '**✅ No changes recommended**'
      end
    end

    # Names the reviewed commit so a later, collapsed copy of this comment
    # still says which push it covered.
    def md_heading
      sha = @report.target.commit_sha
      sha ? "### Review of `#{sha.to_s[0, 7]}`" : '### Review'
    end

    def md_files_reviewed
      files = @report.processed_files
      return if files.empty?

      "<details><summary>Files reviewed (#{files.size})</summary>\n\n" \
        "#{files.map { |file| "- `#{file}`" }.join("\n")}\n\n</details>"
    end

    # Same shape as the approval comment's details block.
    def md_run_info
      target = @report.target
      rows = ["- Thingie version: #{Thingie::VERSION}"]
      rows << "- Review model: #{@report.model}" unless @report.model.to_s.strip.empty?
      rows << "- Base: `#{short_ref(target.base_ref)}`" if target.base_ref
      rows << "- Reviewed at: #{Time.parse(@report.created_at).utc.strftime('%Y-%m-%d %H:%M UTC')}"
      "<details><summary>Thingie details</summary>\n\n#{rows.join("\n")}\n\n</details>"
    end

    def short_ref(ref)
      ref.match?(/\A\h{40}\z/) ? ref[0, 7] : ref
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
