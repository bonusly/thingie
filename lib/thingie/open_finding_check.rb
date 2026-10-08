# frozen_string_literal: true

module Thingie
  # Checks Thingie comments that are still open on a pull request against the current code, so the summary
  # does not list a problem as open after it was fixed on a different line from the comment. One model call
  # per file, no tools, over the current file and the open findings about it.
  class OpenFindingCheck
    FIXED = :fixed
    OPEN = :open
    UNSURE = :unsure

    CONTENT_LIMIT = 60_000

    # Builds a check that asks the given model whether findings are fixed.
    #
    # @param llm_client [Thingie::LlmClient] the client used for the check
    # @param prompt_builder [Thingie::PromptBuilder] renders the check prompt
    def initialize(llm_client:, prompt_builder:)
      @llm_client = llm_client
      @prompt_builder = prompt_builder
    end

    # Says where each open finding stands in the current code.
    #
    # @param findings [Array<Hash>] open findings, each `{ id:, file:, line:, text: }`
    # @param load_file [Proc] block given a file path; returns the file's current content, or nil when the file
    #   no longer exists
    # @return [Hash{Object => Symbol}] each finding's id mapped to `:fixed`, `:open` or `:unsure`
    # @raise [StandardError] when a model call or its reply fails; callers decide how to fall back
    def call(findings, &load_file)
      findings.group_by { |finding| finding[:file] }.each_with_object({}) do |(path, group), statuses|
        statuses.merge!(statuses_for(path, group, load_file.call(path)))
      end
    end

    private

    # A file that no longer exists takes its problems with it. Anything else the model cannot confirm is `:unsure`.
    def statuses_for(path, group, content)
      return group.to_h { |finding| [finding[:id], FIXED] } if content.nil?

      verdicts = verdicts_for(path, group, content)
      group.to_h { |finding| [finding[:id], status_of(verdicts["F#{group.index(finding) + 1}"])] }
    end

    def verdicts_for(path, group, content)
      prompt = @prompt_builder.resolution(
        path: path, content: numbered(content[0, CONTENT_LIMIT]), truncated: content.size > CONTENT_LIMIT,
        findings: group.each_with_index.map { |finding, index| described(finding, index) }
      )
      reply = @llm_client.complete_with_schema(prompt, Schemas::RESOLUTION_SCHEMA).content
      reply = JsonExtractor.parse(reply) if reply.is_a?(String)
      entries = reply.is_a?(Hash) ? reply['findings'] : nil
      raise ArgumentError, 'resolution check returned no findings list' unless entries.is_a?(Array)

      entries.to_h { |entry| [entry['id'].to_s, entry['status'].to_s] }
    end

    def status_of(verdict)
      case verdict
      when 'fixed' then FIXED
      when 'still_present' then OPEN
      else UNSURE
      end
    end

    def described(finding, index)
      location = finding[:line] ? "line #{finding[:line]} when it was posted" : 'no line'
      { label: "F#{index + 1}", location: location, text: finding[:text].to_s.strip[0, DuplicateFilter::TEXT_LIMIT] }
    end

    def numbered(content)
      content.each_line.with_index(1).map { |line, number| "#{number}: #{line}" }.join
    end
  end
end
