# frozen_string_literal: true

require 'json'
require_relative 'concurrency'

module Thingie
  # Critic / challenge pass: re-examines each surviving finding with a fresh,
  # adversarially-framed LLM call. Drops findings it can't uphold, and may also
  # correct the severity/confidence of ones it keeps when the first-pass grade
  # was miscalibrated. Runs only on findings that passed the threshold filter,
  # so cost scales with finding count, not file size.
  #
  # Fail-open: if a verdict can't be obtained or parsed, the finding is KEPT
  # UNCHANGED and a warning is recorded — a broken critic must never silently
  # swallow a real bug or corrupt its grade.
  class Verifier
    attr_reader :warnings

    # Builds a verifier for a single run of the critic pass.
    #
    # @param config [Thingie::Configuration] full merged configuration, including the `[verify]` section
    # @param changeset [Thingie::Changeset] used to fetch diff/full content for each finding's file
    # @param prompt_builder [Thingie::PromptBuilder] builds the critic prompt
    # @param llm_client [Thingie::LlmClient] fallback client, reused when no dedicated `verify.model` is set
    # @param tools [Array, nil] `ruby_llm` tools (e.g. LSP symbol lookup) made available to the critic LLM
    # @param debug_output [Thingie::DebugOutput, nil] optional debug output sink
    # @param usage [Thingie::Stats::Usage, nil] optional accumulator fed each critic response
    def initialize(config:, changeset:, prompt_builder:, llm_client:, tools: [], debug_output: nil, usage: nil)
      @config = config
      @changeset = changeset
      @prompt_builder = prompt_builder
      @tools = tools || []
      @llm_client = verify_client(config, llm_client)
      @debug_output = debug_output
      @usage = usage
      @warnings = []
    end

    # Re-check each finding with the critic LLM, drop the ones it can't uphold,
    # and apply any severity/confidence correction to the ones it keeps.
    # Returns all issues unchanged when verification is disabled or there's nothing to check.
    #
    # @param issues [Array<Thingie::Issue>] surviving findings from the first pass
    # @return [Array<Thingie::Issue>] findings upheld by the critic (or all of them, if disabled)
    def call(issues)
      return issues if issues.empty? || !enabled?

      concurrency = [@config['max_concurrent_tasks'] || 10, 1].max
      verdicts = verify_in_parallel(issues, concurrency)
      issues.zip(verdicts).select { |_issue, verdict| verdict[:keep] }.map do |issue, verdict|
        issue.apply_override(severity: verdict[:severity], confidence: verdict[:confidence])
        issue
      end
    end

    # Fail-open default for a slot whose critic call never completes: keep the
    # finding, unchanged.
    FAIL_OPEN_RESULT = { keep: true, severity: nil, confidence: nil }.freeze

    private

    def settings
      base = (@config['verify'] || {}).transform_keys(&:to_s)
      base['enabled'] = %w[true 1].include?(Env['VERIFY_ENABLED'].to_s.downcase) if Env.key?('VERIFY_ENABLED')
      base['model'] = Env['VERIFY_MODEL'] if Env.key?('VERIFY_MODEL')
      base
    end

    def enabled?
      settings.fetch('enabled', true)
    end

    # Use a dedicated client (same provider/keys) when a critic model is set,
    # otherwise reuse the review client.
    def verify_client(config, llm_client)
      model = settings['model']
      model && !model.to_s.strip.empty? ? LlmClient.new(config, model: model) : llm_client
    end

    # Ordered verdicts via the shared bounded-fiber runner; an issue whose
    # critic call never completes keeps its fail-open slot value.
    def verify_in_parallel(issues, concurrency)
      Concurrency.map(issues, concurrency, default: FAIL_OPEN_RESULT) { |issue| uphold?(issue) }
    end

    # @return [Hash] `{ keep:, severity:, confidence: }` — `severity`/`confidence`
    #   are non-nil only when the critic supplied a validated override.
    def uphold?(issue)
      prompt = @prompt_builder.verify(
        issue: issue,
        diff: @changeset.diff_text_for(issue.file),
        file_lines: @changeset.full_content_for(issue.file),
        symbol_lookup: @tools.any?
      )
      response = @llm_client.complete_with_schema(prompt, Schemas::VERDICT_SCHEMA, tools: @tools)
      @usage&.record(response)
      content = parse_content(response)
      verdict = content['verdict'].to_s.strip.downcase
      @debug_output&.critic_call(issue: issue, response: response,
                                 verdict: verdict.empty? ? '(no verdict)' : verdict,
                                 content: content)
      {
        keep: verdict != 'reject',
        severity: valid_override(content['severity_override'], @config.severity_scale),
        confidence: valid_override(content['confidence_override'], @config.confidence_scale)
      }
    rescue StandardError => e
      # Fail open: keep the finding unchanged, but surface that the critic didn't run.
      @warnings << "Could not verify finding '#{issue.title}' (#{issue.file}): #{e.class}: #{e.message}"
      @debug_output&.critic_error(issue: issue, error: e)
      FAIL_OPEN_RESULT
    end

    def parse_content(response)
      content = response&.content
      content = JSON.parse(content) if content.is_a?(String)
      content.is_a?(Hash) ? content.transform_keys(&:to_s) : {}
    end

    # A malformed or out-of-range override is a no-op rather than an error —
    # bad override data must never corrupt the finding.
    def valid_override(value, scale)
      valid_levels = scale.keys.map { |k| Integer(k, exception: false) }.compact
      level = Integer(value, exception: false)
      return nil if level.nil? || !valid_levels.include?(level)

      level
    end
  end
end
