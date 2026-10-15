# frozen_string_literal: true

module Thingie
  # Drops review findings that repeat another finding in the same run, or a
  # review comment that is still open or that a person answered, so a re-run does not
  # post the same problem a second time. One model call, no tools, over the whole
  # list: the wording of a finding changes between runs, so matching by title or
  # line would miss most repeats. Of several repeats the most severe is kept,
  # and at equal severity the one on source code wins over the one on a test.
  class DuplicateFilter
    TEXT_LIMIT = 600
    TEST_PATH = %r{(?:\A|/)(?:spec|test|tests|__tests__)/|[._](?:spec|test)\.\w+\z}

    # Builds a filter that asks the given model whether findings repeat each other.
    #
    # @param llm_client [Thingie::LlmClient] the client used for the duplicate check
    # @param prompt_builder [Thingie::PromptBuilder] renders the duplicate-check prompt
    def initialize(llm_client:, prompt_builder:)
      @llm_client = llm_client
      @prompt_builder = prompt_builder
    end

    # Returns the findings to post, without the ones that repeat another finding or an open comment. A finding
    # dropped as a repeat of another new finding is noted on the one kept (`Issue#also_found`), so its thread
    # says where else the problem was seen.
    #
    # @param issues [Array<Thingie::Issue>] the findings about to be posted
    # @param open_comments [Array<Hash>] earlier Thingie comments, open or answered, each `{ file:, line:, text: }`
    # @return [Array<Thingie::Issue>] the findings to post, in their original order
    # @raise [StandardError] when the model call or its reply fails; callers decide how to fall back
    def call(issues, open_comments)
      return issues if issues.empty? || (issues.size < 2 && open_comments.empty?)

      ranked = issues.sort_by.with_index { |issue, index| [*rank_of(issue), index] }
      verdicts = verdicts_for(ranked, open_comments)
      dropped = dropped_labels(ranked, verdicts, open_comments.size)
      note_repeats(ranked, verdicts, dropped)
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

    def note_repeats(ranked, verdicts, dropped)
      ranked.each_with_index do |issue, index|
        next unless dropped.include?("N#{index + 1}")

        kept_finding(ranked, verdicts, dropped, index)&.add_also_found(location_of(issue))
      end
    end

    # Follows a dropped finding's pointer through any findings that were dropped too, to the one that is
    # posted. Nil when the chain ends at an open comment. Pointers only go to earlier findings, so it ends.
    def kept_finding(ranked, verdicts, dropped, index)
      loop do
        match = verdicts["N#{index + 1}"].to_s.strip.match(/\AN(\d+)\z/)
        return unless match

        index = match[1].to_i - 1
        return ranked[index] unless dropped.include?("N#{index + 1}")
      end
    end

    def location_of(issue)
      [File.basename(issue.file.to_s), line_of(issue)].compact.join(':')
    end

    def repeats_open_comment?(target, open_count)
      match = target.match(/\AE(\d+)\z/)
      match && match[1].to_i.between?(1, open_count)
    end

    def repeats_earlier?(target, index)
      match = target.match(/\AN(\d+)\z/)
      match && match[1].to_i.between?(1, index)
    end

    def rank_of(issue)
      [issue.severity || 99, issue.file.to_s.match?(TEST_PATH) ? 1 : 0]
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
