# frozen_string_literal: true

require 'json'

module Thingie
  # Emits debug progress to $stderr when a review runs in debug mode. Kept as a
  # standalone object so the Reviewer stays focused on orchestration: it just
  # calls the appropriate hook methods and this class decides what to print.
  #
  # Section tags: [DEBUG][REVIEW] for per-call initial-review lines,
  # [DEBUG][CRITIC] for per-call critic-pass lines, plain [DEBUG] for summaries.
  # Formats and prints the per-response detail blocks: reasoning/thinking
  # output, parsed issue details, raw response content, and critic verdict
  # details. Extracted from DebugOutput so the hook class stays under the
  # class-length limit; these are pure formatting helpers that call `warn`
  # directly (writes to $stderr, same channel DebugOutput uses).
  class DebugDetail
    # Prints the LLM's reasoning/thinking output if the provider returned any.
    # Providers like Anthropic and OpenAI (o-series) return this alongside the
    # main content; most other providers return nil, in which case nothing is
    # printed.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @param tag [String] the debug section tag (REVIEW or CRITIC)
    # @return [void]
    def reasoning(response, tag:)
      thinking = response&.thinking
      return unless thinking

      text = thinking.respond_to?(:text) ? thinking.text : thinking.to_s
      return if text.nil? || text.to_s.strip.empty?

      thinking_tokens = response&.thinking_tokens
      token_note = thinking_tokens&.positive? ? " (#{thinking_tokens} tokens)" : ''
      warn "[DEBUG][#{tag}]   reasoning#{token_note}:"
      text.to_s.split("\n").each do |line|
        warn "[DEBUG][#{tag}]     #{line}"
      end
    end

    # Prints a one-line detail for each parsed issue from the review pass,
    # showing severity, confidence, tags, title, and affected line ranges.
    #
    # @param issues [Array<Thingie::Issue>] the parsed issues
    # @param tag [String] the debug section tag
    # @return [void]
    def issues(issues, tag:)
      warn "[DEBUG][#{tag}]   issues:"
      issues.each_with_index do |issue, i|
        locations = issue.affected_lines.map do |range|
          if range.start_line && range.end_line && range.start_line != range.end_line
            "lines #{range.start_line}-#{range.end_line}"
          elsif range.start_line
            "line #{range.start_line}"
          end
        end.compact
        location = locations.any? ? " (#{locations.join(', ')})" : ''
        tags = issue.tags&.any? ? issue.tags.join(',') : 'none'
        warn format(
          '[DEBUG][%<tag>s]     %<idx>d. [sev=%<sev>s conf=%<conf>s] %<tags>s: %<title>s%<loc>s',
          tag: tag, idx: i + 1, sev: issue.severity, conf: issue.confidence,
          tags: tags, title: issue.title, loc: location
        )
      end
    end

    # Prints the full parsed response content (the raw JSON the LLM returned),
    # pretty-printed for readability. Useful for debugging malformed or
    # unexpected LLM output that the IssueParser may have silently dropped.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @param tag [String] the debug section tag
    # @return [void]
    def content(response, tag:)
      parsed = parse_raw_content(response)
      return if parsed.nil?

      warn "[DEBUG][#{tag}]   response content:"
      formatted = parsed.is_a?(String) ? parsed : JSON.pretty_generate(parsed)
      formatted.split("\n").each do |line|
        warn "[DEBUG][#{tag}]     #{line}"
      end
    rescue StandardError
      # If we can't pretty-print (non-JSON-serializable content), show the raw value.
      warn "[DEBUG][#{tag}]   response content: #{response&.content}"
    end

    # Prints the parsed critic verdict content in a readable key-value format,
    # showing the verdict, any severity/confidence overrides, and the critic's
    # reasoning. Only non-nil/non-empty fields are shown.
    #
    # @param content [Hash, nil] the parsed verdict hash from the critic response
    # @param tag [String] the debug section tag
    # @return [void]
    def verdict(content, tag:)
      return if content.nil? || content.empty?

      primary = %w[verdict severity_override confidence_override].each_with_object([]) do |key, acc|
        val = content[key]
        next if val.nil? || (val.respond_to?(:empty?) && val.empty?)

        acc << "#{key}: #{val}"
      end
      warn "[DEBUG][#{tag}]   #{primary.join(' | ')}" if primary.any?

      reasoning = content['reasoning']
      if reasoning && !reasoning.to_s.strip.empty?
        warn "[DEBUG][#{tag}]   critic reasoning:"
        reasoning.to_s.split("\n").each do |line|
          warn "[DEBUG][#{tag}]     #{line}"
        end
      end

      # Surface any unexpected keys the schema didn't define.
      extras = content.keys - %w[verdict severity_override confidence_override reasoning]
      extras.each do |key|
        warn "[DEBUG][#{tag}]   #{key}: #{content[key]}"
      end
    end

    # Formats a one-line token usage summary from a ruby_llm response.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @return [String] a token summary string like "tokens: 100 in / 50 out / 150 total"
    def token_summary(response)
      input = response&.input_tokens
      output = response&.output_tokens
      return 'tokens: n/a' if input.nil? && output.nil?

      parts = ["#{input || '?'} in", "#{output || '?'} out"]
      parts << "#{input + output} total" if input && output
      cache_read = response&.cache_read_tokens
      parts << "#{cache_read} cache_read" if cache_read&.positive?
      cache_write = response&.cache_write_tokens
      parts << "#{cache_write} cache_write" if cache_write&.positive?
      thinking = response&.thinking_tokens
      parts << "#{thinking} thinking" if thinking&.positive?
      context = context_window_summary(response, input, output)
      parts << context if context
      "tokens: #{parts.join(' / ')}"
    end

    # Formats the cost from a ruby_llm response, or nil if unavailable.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @return [String, nil] a cost string like "cost: $0.000123", or nil
    def cost_summary(response)
      return nil unless response

      total = response.cost.total
      return nil if total.nil?

      format('cost: $%.6f', total)
    rescue StandardError
      nil
    end

    # Summarizes tool calls from a ruby_llm response, or nil if none.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @return [String, nil] a tool-call summary, or nil if no tool calls
    def tool_calls_summary(response)
      calls = response&.tool_calls
      return nil if calls.nil? || (calls.respond_to?(:empty?) && calls.empty?)

      if calls.is_a?(Hash)
        by_name = calls.values.group_by { |tc| tc.respond_to?(:name) ? tc.name : tc.to_s }
        by_name.map { |name, group| "#{name}(#{group.size})" }.join(', ')
      else
        "#{calls.size} call(s)"
      end
    end

    private

    # Approximates context-window pressure by comparing input+output against
    # the model's static context_window limit. RubyLLM doesn't return an
    # actual "context used" figure from the provider.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @param input [Integer, nil] input token count
    # @param output [Integer, nil] output token count
    # @return [String, nil] a context usage string, or nil if unavailable
    def context_window_summary(response, input, output)
      return nil unless input && output

      window = response&.model_info&.context_window
      return nil unless window&.positive?

      used = input + output
      format('%<used>d/%<window>d ctx (%<pct>.1f%%)', used: used, window: window, pct: (used * 100.0 / window))
    rescue StandardError
      nil
    end

    # Extracts and parses the raw content from a ruby_llm response. Handles
    # both pre-parsed Hash/Array content (from structured output mode) and raw
    # JSON strings. Returns nil for nil or empty content.
    #
    # @param response [Object, nil] the ruby_llm response object
    # @return [Object, nil] the parsed content, or the raw string if unparseable
    def parse_raw_content(response)
      content = response&.content
      return nil if content.nil?
      return nil if content.is_a?(String) && content.strip.empty?

      content.is_a?(String) ? JSON.parse(content) : content
    rescue JSON::ParserError
      content
    end
  end

  # Emits debug progress to $stderr when a review runs in debug mode. Kept as a
  # standalone object so the Reviewer stays focused on orchestration: it just
  # calls the appropriate hook methods and this class decides what to print.
  #
  # Section tags: [DEBUG][REVIEW] for per-call initial-review lines,
  # [DEBUG][CRITIC] for per-call critic-pass lines, plain [DEBUG] for summaries.
  class DebugOutput
    # Builds a debug output sink for a single review run.
    #
    # @param config [Thingie::Configuration] the resolved run configuration
    # @param changeset [Thingie::Changeset] the changeset being reviewed
    # @param enabled [Boolean] whether debug output should actually be printed
    def initialize(config:, changeset:, enabled: false)
      @config = config
      @changeset = changeset
      @enabled = enabled
      @detail = DebugDetail.new
    end

    # Prints the run summary banner (model, critic model, files under review).
    #
    # @return [void]
    def banner
      return unless @enabled

      files = @changeset.files
      warn '[DEBUG] Review starting'
      warn "[DEBUG] Model: #{@config['model']} | Provider: #{@config['provider']}"
      critic_model = @config.dig('verify', 'model')
      critic_line = critic_model && !critic_model.to_s.strip.empty? ? critic_model : 'reusing review model'
      warn "[DEBUG] Critic model: #{critic_line}"
      warn "[DEBUG] Files (#{files.size}): #{files.join(', ')}"
    end

    # Prints the header line marking the start of the initial review pass.
    #
    # @return [void]
    def review_section_start
      return unless @enabled

      warn "[DEBUG] --- Initial Review Pass (#{@changeset.files.size} file(s)) ---"
    end

    # Called after each individual file review LLM call completes. Prints token
    # usage, cost, tool calls, reasoning/thinking output (if any), a per-issue
    # detail line for each parsed finding, and the raw parsed response content.
    #
    # @param file [String] the file that was reviewed
    # @param response [Object, nil] the `ruby_llm` response object for the call
    # @param issues [Array<Thingie::Issue>] the parsed issues from the response
    # @return [void]
    def review_call(file:, response:, issues:)
      return unless @enabled

      parts = ["#{issues.size} issue(s) found", @detail.token_summary(response)]
      cost = @detail.cost_summary(response)
      parts << cost if cost
      warn "[DEBUG][REVIEW] #{file}: #{parts.join(' | ')}"
      tool_info = @detail.tool_calls_summary(response)
      warn "[DEBUG][REVIEW]   tool calls: #{tool_info}" if tool_info
      @detail.reasoning(response, tag: 'REVIEW')
      @detail.issues(issues, tag: 'REVIEW') if issues.any?
      @detail.content(response, tag: 'REVIEW')
    end

    # Called when a file review's LLM response can't be parsed.
    #
    # @param file [String] the file whose review failed
    # @param error [StandardError] the exception that was raised
    # @return [void]
    def review_error(file:, error:)
      return unless @enabled

      warn "[DEBUG][REVIEW] ERROR #{file}: #{error.class}: #{error.message}"
    end

    # Prints a summary of the surviving findings after the initial pass,
    # grouped by file and by severity.
    #
    # @param issues [Array<Thingie::Issue>] findings after threshold + changed-line filters
    # @return [void]
    def first_pass(issues)
      return unless @enabled

      warn "[DEBUG] First pass: #{issues.size} findings (after threshold + changed-line filters)"
      issues.group_by(&:file).each do |file, file_issues|
        warn "[DEBUG]   #{file}: #{file_issues.size}"
      end
      issues.group_by(&:severity).each do |severity, sev_issues|
        warn "[DEBUG]   Severity distribution: severity=#{severity} -> #{sev_issues.size}"
      end
    end

    # Prints how many findings the PostProcessor threshold filter dropped.
    #
    # @param before [Integer] finding count before the threshold filter
    # @param after [Integer] finding count after the threshold filter
    # @return [void]
    def post_process(before:, after:)
      return unless @enabled

      dropped = before - after
      warn "[DEBUG] Post-process: #{before} -> #{after} findings (dropped #{dropped} by threshold)"
    end

    # Prints the header line marking the start of the critic pass.
    #
    # @return [void]
    def critic_section_start
      return unless @enabled

      warn '[DEBUG] --- Critic Pass ---'
    end

    # Called after each individual critic/verifier LLM call completes. Prints
    # token usage, cost, tool calls, reasoning/thinking output (if any), and
    # the full parsed verdict content including any severity/confidence overrides.
    #
    # @param issue [Thingie::Issue] the finding being verified
    # @param response [Object, nil] the `ruby_llm` response object for the call
    # @param verdict [Symbol, String] the critic's verdict for this finding
    # @param content [Hash, nil] the parsed verdict hash from the critic response
    # @return [void]
    def critic_call(issue:, response:, verdict:, content:)
      return unless @enabled

      parts = [@detail.token_summary(response)]
      cost = @detail.cost_summary(response)
      parts << cost if cost
      warn "[DEBUG][CRITIC] '#{issue.title}' (#{issue.file}) -> #{verdict} | #{parts.join(' | ')}"
      tool_info = @detail.tool_calls_summary(response)
      warn "[DEBUG][CRITIC]   tool calls: #{tool_info}" if tool_info
      @detail.reasoning(response, tag: 'CRITIC')
      @detail.verdict(content, tag: 'CRITIC')
    end

    # Called when a critic/verifier LLM call fails with an exception.
    #
    # @param issue [Thingie::Issue] the finding that was being verified
    # @param error [StandardError] the exception that was raised
    # @return [void]
    def critic_error(issue:, error:)
      return unless @enabled

      warn "[DEBUG][CRITIC] ERROR '#{issue.title}' (#{issue.file}): #{error.class}: #{error.message}"
    end

    # Prints a summary of what the critic pass dropped, comparing the findings
    # that went in against the findings that survived.
    #
    # @param input [Array<Thingie::Issue>] findings before the critic pass
    # @param kept [Array<Thingie::Issue>] findings the critic pass kept
    # @return [void]
    def critic(input, kept)
      return unless @enabled

      # Issues are compared by object identity (Issue has no == override and
      # the Verifier returns the same objects it received), so Array#- finds
      # exactly the findings the critic dropped.
      dropped = input - kept
      warn "[DEBUG] Critic pass: dropped #{dropped.size} of #{input.size} findings"
      dropped.each do |issue|
        warn "[DEBUG]   DROPPED: '#{issue.title}' (#{issue.file}, severity=#{issue.severity})"
      end
    end

    # Prints the accumulated pipeline warnings (parse failures, critic errors,
    # etc.) at the end of the review run.
    #
    # @param warnings [Array<String>] the warnings collected during the run
    # @return [void]
    def warnings(warnings)
      return unless @enabled
      return if warnings.nil? || warnings.empty?

      warn "[DEBUG] Warnings (#{warnings.size}):"
      warnings.each_with_index do |warning, i|
        warn "[DEBUG]   #{i + 1}. #{warning}"
      end
    end
  end
end
