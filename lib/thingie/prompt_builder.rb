# frozen_string_literal: true

require 'erb'
require 'json'

module Thingie
  # Builds prompts for the review LLM by rendering bundled ERB templates with
  # configuration values. Skills are not inlined here — they're exposed to
  # the LLM via SkillCatalog's progressive-disclosure tool instead.
  class PromptBuilder
    REVIEW_TEMPLATES = {
      'default' => File.expand_path('prompts/review.erb', __dir__),
      'verified' => File.expand_path('prompts/review_verified.erb', __dir__)
    }.freeze
    VERIFY_TEMPLATE = File.expand_path('prompts/verify.erb', __dir__)
    DUPLICATES_TEMPLATE = File.expand_path('prompts/duplicates.erb', __dir__)
    COMMENT_STYLE_FILE = File.expand_path('prompts/comment_style.txt', __dir__)

    # ERB's result_with_hash raises NameError for any var referenced in a
    # template but absent from the hash, so these (used unconditionally in
    # review.erb/verify.erb) need a default even when prompt_vars omits them.
    DEFAULT_TEMPLATE_VARS = {
      'requirements' => '', 'json_requirements' => '', 'self_id' => '', 'severity_rubric' => ''
    }.freeze

    attr_reader :config

    # Builds a prompt builder backed by the given configuration.
    #
    # @param config [Thingie::Configuration] provides `prompt_vars`, `severity_scale`, `confidence_scale`,
    #   `show_threshold`, and `block_threshold`
    def initialize(config)
      @config = config
    end

    # Render the review prompt (`review.erb`) for a single file's diff.
    #
    # @param diff [String, nil] the diff text (or full content in `all` mode) to review
    # @param file_lines [String, nil] the full file content, given as extra context to the LLM
    # @param symbol_lookup [Boolean] whether the LSP symbol-lookup tool is available to the LLM
    # @param pr_context [String] the list of files the PR touches (see PrContext)
    # @param whole_file [Boolean] whether this is a whole-file review (`--all` mode, no diff);
    #   switches the prompt guideline from "only changed lines" to "every line"
    # @param tool_budget [Integer, nil] the most tool calls the model may make, told to it; nil for no cap
    # @return [String] the rendered prompt text
    def review(diff:, file_lines: nil, symbol_lookup: false, whole_file: false, pr_context: '', tool_budget: nil)
      render_template(review_template, 'input' => diff, 'file_lines' => file_lines, 'pr_context' => pr_context,
                                       'symbol_lookup' => symbol_lookup, 'whole_file' => whole_file,
                                       'tool_budget' => tool_budget,
                                       'severity_scale' => format_scale(@config.severity_scale),
                                       'confidence_scale' => format_scale(@config.confidence_scale),
                                       'show_threshold_text' => show_threshold_text,
                                       'block_threshold_text' => block_threshold_text)
    end

    # Render the critic/verify prompt (`verify.erb`) that re-checks a single finding.
    #
    # @param issue [Thingie::Issue] the finding to verify
    # @param diff [String, nil] the diff text (or full content in `all` mode) the finding was raised against
    # @param file_lines [String, nil] the full file content, given as extra context to the LLM
    # @param symbol_lookup [Boolean] whether the LSP symbol-lookup tool is available to the LLM
    # @param pr_context [String] the list of files the PR touches (see PrContext)
    # @param tool_budget [Integer, nil] the most tool calls the model may make, told to it; nil for no cap
    # @return [String] the rendered prompt text
    def verify(issue:, diff:, file_lines: nil, symbol_lookup: false, pr_context: '', tool_budget: nil)
      render_template(VERIFY_TEMPLATE, 'input' => diff, 'file_lines' => file_lines, 'pr_context' => pr_context,
                                       'symbol_lookup' => symbol_lookup, 'tool_budget' => tool_budget,
                                       'finding' => format_finding(issue),
                                       'user_impact' => @config.dig('verify', 'bar') == 'user_impact',
                                       'severity_scale' => format_scale(@config.severity_scale),
                                       'confidence_scale' => format_scale(@config.confidence_scale),
                                       'show_threshold_text' => show_threshold_text,
                                       'block_threshold_text' => block_threshold_text)
    end

    # Render the repeat-check prompt (`duplicates.erb`) that asks which new findings repeat an earlier one.
    #
    # @param existing [Array<Hash>] the comments already open on the PR, each `{ label:, location:, text: }`
    # @param findings [Array<Hash>] the new findings, each `{ label:, location:, text: }`
    # @return [String] the rendered prompt text
    def duplicates(existing:, findings:)
      render_template(DUPLICATES_TEMPLATE, 'existing' => existing, 'findings' => findings)
    end

    private

    # `[review] prompt` picks the bundled review prompt: `default` (strict, report only what is certain)
    # or `verified` (check suspicions with the tools, cite evidence, grade confidence by verification).
    def review_template
      style = @config.dig('review', 'prompt').to_s
      REVIEW_TEMPLATES.fetch(style.empty? ? 'default' : style) do
        raise ArgumentError, "Unknown [review] prompt #{style.inspect}; expected #{REVIEW_TEMPLATES.keys.join(' or ')}"
      end
    end

    def render_template(path, vars)
      ERB.new(template_cache(path), trim_mode: '-').result_with_hash(template_vars.merge(vars))
    end

    def template_cache(path)
      @template_cache ||= {}
      @template_cache[path] ||= File.read(path, encoding: 'UTF-8')
    end

    # `comment_style` can be replaced from `[prompt_vars]` like the other template variables.
    def template_vars
      DEFAULT_TEMPLATE_VARS.merge('comment_style' => comment_style).merge(prompt_vars)
    end

    # How a finding's title and details should be written, shared by both review prompts.
    def comment_style
      @comment_style ||= File.read(COMMENT_STYLE_FILE, encoding: 'UTF-8')
    end

    # Normalize to string keys so symbol-keyed config can't silently miss lookups.
    def prompt_vars
      @prompt_vars ||= @config.prompt_vars.transform_keys(&:to_s)
    end

    # Render a single issue for the critic prompt: title, details, current
    # severity/confidence grade (the critic's anchor for any correction), and
    # each affected range with the actual code (set by CodeEnricher before verify).
    def format_finding(issue)
      ranges = issue.affected_lines.map do |range|
        loc = "lines #{range.start_line}-#{range.end_line || range.start_line}"
        code = range.affected_code ? "\n#{range.affected_code}" : ''
        "#{loc}:#{code}"
      end.join("\n")
      tags = Array(issue.tags).join(', ')
      "File: #{issue.file}\nTitle: #{issue.title}\nTags: #{tags}\n" \
        "Severity: #{issue.severity} (#{label_for(@config.severity_scale, issue.severity)})\n" \
        "Confidence: #{issue.confidence} (#{label_for(@config.confidence_scale, issue.confidence)})\n" \
        "Details: #{issue.details}\n#{evidence_line(issue)}Affected code:\n#{ranges}"
    end

    def evidence_line(issue)
      issue.evidence.to_s.strip.empty? ? '' : "Evidence the reviewer gave: #{issue.evidence}\n"
    end

    def format_scale(scale)
      return '' unless scale.is_a?(Hash) && !scale.empty?

      scale.sort_by { |k, _| k.to_s.to_i }.map { |level, label| "- #{level} — #{label}" }.join("\n")
    end

    def label_for(scale, level)
      return level.to_s unless scale.is_a?(Hash)

      scale[level.to_s] || scale[level] || level.to_s
    end

    # A sentence stating the "show" line in the reviewer's own reasoning terms:
    # what severity/confidence a finding needs to be surfaced to maintainers at all.
    def show_threshold_text
      threshold = @config.show_threshold
      bars = [
        bar_text('severity', threshold[:max_severity], @config.severity_scale),
        bar_text('confidence', threshold[:max_confidence], @config.confidence_scale)
      ].compact
      if bars.empty?
        return 'Every finding you report is shown to maintainers as a PR comment ' \
               '(no show-line threshold is configured).'
      end

      "Only findings that meet #{bars.join(' and ')} are shown to maintainers as a PR comment — " \
        'weaker findings are recorded but never posted, so reporting one below this bar wastes the review.'
    end

    # A sentence stating the "block" line: what severity a finding needs to
    # prevent this PR from being auto-approved, independent of the show line above.
    def block_threshold_text
      threshold = @config.block_threshold
      unless threshold[:enabled]
        return 'Auto-approval is not enabled for this project, so no severity blocks approval automatically.'
      end

      max_severity = threshold[:max_severity]
      unless max_severity
        return 'Auto-approval is enabled with no severity threshold configured, so no severity blocks approval.'
      end

      bar = bar_text('severity', max_severity, @config.severity_scale)
      "Findings at #{bar} also block this PR from auto-approval; findings below that do not block."
    end

    def bar_text(dimension, level, scale)
      return nil unless level

      "#{dimension} #{level} (#{label_for(scale, level)}) or better"
    end
  end
end
