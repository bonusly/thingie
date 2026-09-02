# frozen_string_literal: true

require 'json'
require_relative 'concurrency'
require_relative 'json_extractor'

module Thingie
  # Orchestrates reviewing the changeset: builds prompts, calls the LLM,
  # post-processes issues, and builds a Report.
  class Reviewer
    # Builds a reviewer for a single run of the pipeline.
    #
    # @param config [Thingie::Configuration] full merged configuration
    # @param changeset [Thingie::Changeset] the files under review
    # @param prompt_builder [Thingie::PromptBuilder] builds review/verify prompts
    # @param llm_client [Thingie::LlmClient] wraps the LLM used for review calls
    # @param tools [Array, nil] `ruby_llm` tools (e.g. LSP symbol lookup) made available to the LLM
    # @param debug [Boolean] enable verbose debug output during the pipeline
    def initialize(config:, changeset:, prompt_builder:, llm_client:, tools: [], debug: false)
      @config = config
      @changeset = changeset
      @prompt_builder = prompt_builder
      @llm_client = llm_client
      @tools = tools || []
      # Plain array: Async runs fibers cooperatively on a single thread, so
      # appends between scheduler yields do not race. No lock needed.
      @warnings = []
      # Per-file review failures ([file, error]). A single failure skips the
      # file with a warning; failures on every file abort the run (see
      # #raise_if_total_failure). Same cooperative-single-thread guarantee.
      @file_failures = []
      # Files the run produced no verdict for, whether the call failed or its
      # response could not be parsed. A report listing any of these covers less
      # than the changeset, so finding nothing in them means nothing, and the
      # approver refuses to approve on it.
      @unreviewed_files = []
      @debug_output = DebugOutput.new(config: config, changeset: changeset, enabled: debug)
      @usage = Stats::Usage.new
    end

    # Accumulated LLM token/cost usage for the run, fed each review and critic
    # response so the stats emitter can report it.
    #
    # @return [Thingie::Stats::Usage] accumulated LLM token/cost usage for the run
    attr_reader :usage

    # Run the full review pipeline: gather LLM findings for each changed file, post-process,
    # enrich with code snippets, run the critic pass, scan changed files for obfuscation
    # (added after the critic pass so thresholds cannot suppress it), sort by severity,
    # and assign issue ids.
    def review
      @debug_output.banner
      @debug_output.review_section_start
      issues = gather_llm_issues
      filtered = PostProcessor.new(@config['post_process']).call(issues)
      @debug_output.post_process(before: issues.size, after: filtered.size)
      enriched = CodeEnricher.new(@changeset).call(filtered)
      @debug_output.first_pass(enriched)
      verified = verify(enriched)
      obfuscated = ObfuscationDetector.new(@changeset).call
      sorted = (verified + obfuscated).sort_by { |issue| issue.severity || Float::INFINITY }
      sorted.each_with_index { |issue, index| issue.id = index + 1 }
      @debug_output.warnings(@warnings)
      build_report(sorted)
    end

    private

    def build_report(issues)
      Report.new(
        target: build_target,
        model: @config['model'],
        issues: issues,
        processing_warnings: @warnings,
        number_of_processed_files: @changeset.files.size,
        unreviewed_files: @unreviewed_files
      )
    end

    def verify(issues)
      @debug_output.critic_section_start
      verifier = Verifier.new(
        config: @config, changeset: @changeset, prompt_builder: @prompt_builder,
        llm_client: @llm_client, tools: @tools, debug_output: @debug_output, usage: @usage
      )
      kept = verifier.call(issues)
      @warnings.concat(verifier.warnings)
      @debug_output.critic(issues, kept)
      kept
    end

    def gather_llm_issues
      files = @changeset.files
      concurrency = [@config['max_concurrent_tasks'] || 10, 1].max
      # Always go through the parallel path (a concurrency of 1 runs serially)
      # so behavior is identical regardless of concurrency.
      issues = review_in_parallel(files, concurrency)
      raise_if_total_failure(files)
      issues
    end

    # Per-file failures are rescued inside #review_file, so the block never
    # raises; a file that fails is skipped with a warning and returns [].
    def review_in_parallel(files, concurrency)
      Concurrency.map(files, concurrency) { |file| review_file(file) }.flatten(1)
    end

    # A review where every file failed (dead API key, unreachable provider)
    # would otherwise "succeed" with an empty report — silently not reviewing
    # anything. Abort instead. Any partial success completes the run; the
    # failed files are listed in the report's processing warnings.
    def raise_if_total_failure(files)
      return unless files.any? && @file_failures.size == files.size

      file, error = @file_failures.first
      raise "All #{files.size} file reviews failed " \
            "(#{file}: #{error.class}: #{error.message}); aborting instead of reporting an empty review"
    end

    def review_file(file)
      # In `--all` mode the "diff" is the full file content; sending it again
      # as context duplicates every byte of the prompt for no information.
      whole_file = @changeset.all?
      diff = @changeset.diff_text_for(file)
      full = whole_file ? nil : @changeset.full_content_for(file)
      prompt = @prompt_builder.review(diff: diff, file_lines: full, symbol_lookup: @tools.any?,
                                      whole_file: whole_file)
      response = @llm_client.complete_with_schema(prompt, Schemas::ISSUE_SCHEMA, tools: @tools)
      @usage.record(response)
      issues = parse_response(response, file)
      @debug_output.review_call(file: file, response: response, issues: issues)
      only_changed_lines(issues, file)
    rescue JSON::ParserError => e
      @warnings << "Could not parse LLM response for #{file}: #{e.message}"
      @unreviewed_files << file
      @debug_output.review_error(file: file, error: e)
      []
    rescue StandardError => e
      @warnings << "Failed to review #{file}: #{e.class}: #{e.message}"
      @file_failures << [file, e]
      @unreviewed_files << file
      @debug_output.review_error(file: file, error: e)
      []
    end

    # The full file is sent to the LLM as context, so it can flag issues on
    # unchanged lines. Drop those: keep only findings touching a changed line,
    # so they don't become off-diff noise in the report and PR comment.
    def only_changed_lines(issues, file)
      changed = @changeset.changed_lines_for(file)
      return issues if changed.nil? # nil = whole-file review (--all), don't filter

      issues.select do |issue|
        issue.affected_lines.any? do |range|
          next false unless range.start_line

          (range.start_line..(range.end_line || range.start_line)).any? { |line| changed.include?(line) }
        end
      end
    end

    def parse_response(response, file)
      content = response&.content
      # A blank response is not "the LLM found nothing" (that comes back as
      # valid JSON with an empty issues array) — it's no verdict at all, so it
      # must flow into the same rescue that unparseable JSON does, or this
      # file silently reads as clean with nothing in unreviewed_files.
      raise JSON::ParserError, 'empty LLM response' if content.to_s.strip.empty?

      parsed = content.is_a?(String) ? JsonExtractor.parse(content) : content
      raise JSON::ParserError, 'no valid JSON found in response' if parsed.nil?

      issues = parsed.is_a?(Hash) ? (parsed['issues'] || parsed[:issues] || []) : parsed
      IssueParser.new.parse(Array(issues), file)
    end

    def build_target
      ReviewTarget.new(
        platform: 'local',
        repo_url: nil,
        pr_number: nil,
        commit_sha: @changeset.head_sha,
        branch: nil,
        base_ref: @changeset.base_ref,
        head_ref: @changeset.head_ref,
        merge_base: false
      )
    end
  end
end
