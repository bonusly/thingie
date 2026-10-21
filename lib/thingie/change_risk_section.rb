# frozen_string_literal: true

module Thingie
  # Renders a report's change-risk summary (see {Thingie::Report#change_risk}) for the CLI and Markdown.
  class ChangeRiskSection
    # Display name for the `overall` score: the model's own judgment of how closely to review a file,
    # not an aggregate of the other questions.
    OVERALL_LABEL = 'review need'

    # Wrap the summary for rendering.
    #
    # @param risk [Hash] the string-keyed change-risk summary stored on the report
    def initialize(risk)
      @risk = risk
    end

    # The rating, each file's rating and scores, and escalations as plain text lines.
    #
    # @return [String] CLI-formatted section
    def to_cli
      files = rows.map { |path, risk| "  - #{path}: #{cli_file(risk)}\n" }.join
      escalation_rows = escalations.map { |escalation| "\n  - #{cli_escalation(escalation)}" }.join
      "Change risk: #{headline}\n#{files}" \
        "Escalations:#{escalation_rows.empty? ? ' none' : escalation_rows}\n"
    end

    # Each file's rating and scores as a table in a collapsed block, with the changeset's rating
    # and any escalation in the summary line so they are visible without opening it.
    #
    # @return [String] Markdown-formatted section
    def to_md
      bullets = escalations.map { |escalation| "- #{md_escalation(escalation)}" }.join("\n")
      "<details><summary>Change risk: #{headline}</summary>\n\n#{md_table}\n\n" \
        "Escalations:#{bullets.empty? ? ' none' : "\n\n#{bullets}"}\n\n</details>"
    end

    private

    # Files by `overall` score, riskiest first; files without one last, then by path.
    def rows
      @rows ||= @risk['files'].sort_by { |path, risk| [-(risk['scores']['overall'] || -1), path] }
    end

    def cli_file(risk)
      scores = risk['scores']
      overall = "#{OVERALL_LABEL} #{score(scores['overall'])}" if scores['overall']
      others = scores.except('overall').map { |question, value| "#{label(question)} #{score(value)}" }
      detail = [overall, others.join(', ')].compact.reject(&:empty?).join('; ')
      "#{"#{risk['rating']} " if risk['rating']}(#{detail})"
    end

    def md_table
      return 'No files were scored.' if rows.empty?

      keys = rows.first.last['scores'].keys
      questions = (['overall'] & keys) + (keys - ['overall'])
      header = ['File', 'Rating', *questions.map { |question| label(question).capitalize }]
      lines = [header, header.map { '---' }]
      rows.each do |path, risk|
        values = questions.map { |question| risk['scores'][question]&.then { |value| score(value) } }
        lines << ["`#{path}`", risk['rating'], *values]
      end
      lines.map { |cells| "| #{cells.join(' | ')} |" }.join("\n")
    end

    def score(value)
      format('%.2f', value)
    end

    def label(question)
      question == 'overall' ? OVERALL_LABEL : question.tr('_', ' ')
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
      if overall
        scored = "#{OVERALL_LABEL} #{score(overall)}"
        parts << (@risk['rating'] ? "#{@risk['rating']} (#{scored})" : scored)
      end
      parts << "escalated: #{escalation_names.join(', ')}" unless escalations.empty?
      parts.empty? ? 'no files scored' : parts.join(', ')
    end

    def escalation_names
      escalations.map { |escalation| escalation['title'] || "`#{escalation['label']}`" }
    end
  end
end
