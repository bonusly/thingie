# frozen_string_literal: true

module Thingie
  # Drops review findings that repeat another finding in the same run, or a
  # review comment that is still open on the pull request, so a re-run does not
  # post the same problem a second time. One model call, no tools, over the whole
  # list: the wording of a finding changes between runs, so matching by title or
  # line would miss most repeats.
  class DuplicateFilter
    TEXT_LIMIT = 600

    # Builds a filter that asks the given model whether findings repeat each other.
    #
    # @param llm_client [Thingie::LlmClient] the client used for the duplicate check
    # @param prompt_builder [Thingie::PromptBuilder] renders the duplicate-check prompt
    def initialize(llm_client:, prompt_builder:)
      @llm_client = llm_client
      @prompt_builder = prompt_builder
    end

    # Returns the findings to post, without the ones that repeat another finding or an open comment.
    #
    # @param issues [Array<Thingie::Issue>] the findings about to be posted
    # @param open_comments [Array<Hash>] open Thingie comments, each `{ file:, line:, text: }`
    # @return [Array<Thingie::Issue>] the findings to post, in their original order
    # @raise [StandardError] when the model call or its reply fails; callers decide how to fall back
    def call(issues, open_comments)
      return issues if issues.empty? || (issues.size < 2 && open_comments.empty?)

      ranked = issues.sort_by.with_index { |issue, index| [issue.severity || 99, index] }
      verdicts = verdicts_for(ranked, open_comments)
      dropped = dropped_labels(ranked, verdicts, open_comments.size)
      ranked_kept = ranked.each_with_index.reject { |_, index| dropped.include?("N#{index + 1}") }.map(&:first)
      issues.select { |issue| ranked_kept.include?(issue) }
    end

    private

    def verdicts_for(ranked, open_comments)
      prompt = @prompt_builder.duplicates(
        existing: open_comments.each_with_index.map { |c, i| describe("E#{i + 1}", c[:file], c[:line], c[:text]) },
        findings: ranked.each_with_index.map do |issue, i|
          describe("N#{i + 1}", issue.file, line_of(issue), summary_of(issue))
        end
      )
      content = @llm_client.complete_with_schema(prompt, Schemas::DUPLICATES_SCHEMA).content
      content = JsonExtractor.parse(content) if content.is_a?(String)
      entries = content.is_a?(Hash) ? content['findings'] : nil
      raise ArgumentError, 'duplicate check returned no findings list' unless entries.is_a?(Array)

      entries.to_h { |entry| [entry['id'].to_s, entry['duplicate_of']&.to_s] }
    end

    # A finding is dropped when it points at an open comment, or at an earlier
    # finding. A pointer to itself, a later finding or an unknown label is
    # ignored, so a confused reply can only keep a finding, never lose one.
    def dropped_labels(ranked, verdicts, open_count)
      ranked.each_index.with_object(Set.new) do |index, dropped|
        target = verdicts["N#{index + 1}"].to_s.strip
        dropped << "N#{index + 1}" if repeats_open_comment?(target, open_count) || repeats_earlier?(target, index)
      end
    end

    def repeats_open_comment?(target, open_count)
      match = target.match(/\AE(\d+)\z/)
      match && match[1].to_i.between?(1, open_count)
    end

    def repeats_earlier?(target, index)
      match = target.match(/\AN(\d+)\z/)
      match && match[1].to_i.between?(1, index)
    end

    def describe(label, file, line, text)
      { label: label, location: line ? "#{file}:#{line}" : file.to_s, text: text.to_s.strip[0, TEXT_LIMIT] }
    end

    def line_of(issue)
      issue.affected_lines.first&.start_line
    end

    def summary_of(issue)
      "#{issue.title}\n#{issue.details}"
    end
  end
end
