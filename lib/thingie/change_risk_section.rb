# frozen_string_literal: true

module Thingie
  # Renders a report's change-risk summary (see {Thingie::Report#change_risk}) for the CLI and Markdown.
  class ChangeRiskSection
    # Wrap the summary for rendering.
    #
    # @param risk [Hash] the string-keyed change-risk summary stored on the report
    def initialize(risk)
      @risk = risk
    end

    # The scores and escalations as plain text lines.
    #
    # @return [String] CLI-formatted section
    def to_cli
      rows = escalations.map { |escalation| "\n  - #{cli_escalation(escalation)}" }.join
      "Change risk: #{@risk['max'].empty? ? 'no files scored' : scores(' ').join(', ')}\n" \
        "Escalations:#{rows.empty? ? ' none' : rows}\n"
    end

    # The scores and escalations as a collapsed block, with the overall score and any escalation
    # in the summary line so they are visible without opening it.
    #
    # @return [String] Markdown-formatted section
    def to_md
      bullets = escalations.map { |escalation| "- #{md_escalation(escalation)}" }.join("\n")
      "<details><summary>Change risk: #{headline}</summary>\n\n#{md_scores}\n\n" \
        "Escalations:#{bullets.empty? ? ' none' : "\n\n#{bullets}"}\n\n</details>"
    end

    private

    def md_scores
      return 'No files were scored.' if @risk['max'].empty?

      rows = scores(': ').map { |score| "- #{score}" }.join("\n")
      "Highest score per question across the changed files:\n\n#{rows}"
    end

    def scores(separator)
      @risk['max'].map { |question, score| "#{question.tr('_', ' ')}#{separator}#{format('%.2f', score)}" }
    end

    def escalations
      Array(@risk['escalations'])
    end

    def cli_escalation(escalation)
      title = escalation['title']
      [title ? "#{title} (#{escalation['label']})" : escalation['label'], escalation['description']].compact.join(': ')
    end

    def md_escalation(escalation)
      title = escalation['title']
      [title ? "**#{title}** (`#{escalation['label']}`)" : "`#{escalation['label']}`",
       escalation['description']].compact.join(': ')
    end

    def headline
      overall = @risk['max']['overall']
      parts = []
      parts << "overall #{format('%.2f', overall)}" if overall
      parts << "escalated: #{escalation_names.join(', ')}" unless escalations.empty?
      parts.empty? ? 'no files scored' : parts.join(', ')
    end

    def escalation_names
      escalations.map { |escalation| escalation['title'] || "`#{escalation['label']}`" }
    end
  end
end
