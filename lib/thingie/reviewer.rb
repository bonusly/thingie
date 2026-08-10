# frozen_string_literal: true

require 'json'
require 'async'
require 'async/semaphore'
require 'async/barrier'
require 'kernel/sync'

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
      @debug_output = DebugOutput.new(config: config, changeset: changeset, enabled: debug)
      @usage = Stats::Usage.new
    end

    # Accumulated LLM token/cost usage for the run, fed each review and critic
    # response so the stats emitter can report it.
    #
    # @return [Thingie::Stats::Usage] accumulated LLM token/cost usage for the run
    attr_reader :usage

    # Run the full review pipeline: gather LLM findings for each changed file, post-process,
    # enrich with code snippets, run the critic pass, sort by severity, and assign issue ids.
    #
    # @return [Thingie::Report] the finished report
    def review
      @debug_output.banner
      @debug_output.review_section_start
      issues = gather_llm_issues
      filtered = PostProcessor.new(@config['post_process']).call(issues)
      enriched = CodeEnricher.new(@changeset).call(filtered)
      @debug_output.first_pass(enriched)
      verified = verify(enriched)
      sorted = verified.sort_by { |issue| issue.severity || Float::INFINITY }
      sorted.each_with_index { |issue, index| issue.id = index + 1 }
      build_report(sorted)
    end

    private

    def build_report(issues)
      Report.new(
        target: build_target,
        model: @config['model'],
        issues: issues,
        processing_warnings: @warnings,
        number_of_processed_files: @changeset.files.size
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
      # so error aggregation is identical regardless of concurrency.
      review_in_parallel(files, concurrency)
    end

    def review_in_parallel(files, concurrency)
      results = Array.new(files.size)
      errors = []
      barrier = nil # declared here so it's in scope for the ensure block below

      # Sync (not Async) so the block always blocks until the barrier is
      # drained, even when invoked inside an existing reactor. Async would
      # return the scheduled task immediately and race ahead to results.
      # Barrier/semaphore are created inside the reactor so they bind to it.
      Sync do
        barrier = Async::Barrier.new
        semaphore = Async::Semaphore.new(concurrency, parent: barrier)
        files.each_with_index do |file, index|
          semaphore.async(parent: barrier) do
            results[index] = review_file(file)
          rescue StandardError => e
            errors << [file, e]
          end
        end
        barrier.wait # drain on normal path; wait can raise and mask errors in ensure
      ensure
        barrier&.stop
      end

      if errors.any?
        message = errors.map { |file, e| "#{file}: #{e.class}: #{e.message}" }.join("\n")
        raise "Parallel review failures (#{errors.size} files):\n#{message}"
      end

      results.flatten(1)
    end

    def review_file(file)
      diff = @changeset.diff_text_for(file)
      full = @changeset.full_content_for(file)
      prompt = @prompt_builder.review(diff: diff, file_lines: full, symbol_lookup: @tools.any?)
      response = @llm_client.complete_with_schema(prompt, Schemas::ISSUE_SCHEMA, tools: @tools)
      @usage.record(response)
      issues = parse_response(response, file)
      @debug_output.review_call(file: file, response: response, issues_found: issues.size)
      only_changed_lines(issues, file)
    rescue JSON::ParserError => e
      @warnings << "Could not parse LLM response for #{file}: #{e.message}"
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
      return [] if content.nil?
      return [] if content.is_a?(String) && content.strip.empty?

      parsed = content.is_a?(String) ? JSON.parse(content) : content
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
