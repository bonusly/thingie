# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'

module Thingie
  # Gathers first-pass findings from a headless Claude Code run instead of
  # Thingie's own per-file LLM review. The CLI runs a project skill (by default
  # `/code-review`) over the whole changeset in the reviewed repo, so it reads
  # the project's `.claude/` skills and rules itself; everything downstream
  # (thresholds, code enrichment, the critic pass, the report and PR comments)
  # is unchanged. Selected with `[review] source = "claude_code"` or
  # `REVIEW_SOURCE=claude_code`.
  class ClaudeCodeSource
    SOURCE_NAME = 'claude_code'

    # Flat variant of ISSUE_SCHEMA: one run covers every file, so each finding
    # carries its own repo-relative path.
    ISSUE_ITEM = Schemas::ISSUE_SCHEMA[:schema][:properties][:issues][:items]
    SCHEMA = {
      type: 'object',
      properties: {
        issues: {
          type: 'array',
          items: ISSUE_ITEM.merge(
            properties: ISSUE_ITEM[:properties].merge(file: { type: 'string' }),
            required: ISSUE_ITEM[:required] + %w[file]
          )
        }
      },
      required: %w[issues],
      additionalProperties: false
    }.freeze

    DEFAULT_SETTINGS = {
      'command' => 'claude',
      'skill' => '/code-review',
      'model' => nil,
      'max_budget_usd' => 5.0,
      'max_turns' => nil,
      'allowed_tools' => ['Read', 'Grep', 'Glob', 'Task', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)'],
      'timeout' => 1800,
      'raw_output_file' => ''
    }.freeze

    # How much of the CLI's own written report is kept in the PR details block.
    NOTES_LIMIT = 4000

    # Whether the configuration selects this source for the first pass.
    #
    # @param config [Thingie::Configuration] the loaded configuration
    # @return [Boolean] true when `REVIEW_SOURCE` or `[review] source` is `claude_code`
    def self.selected?(config)
      source = Env.key?('REVIEW_SOURCE') ? Env['REVIEW_SOURCE'] : config.dig('review', 'source')
      source.to_s.strip.downcase == SOURCE_NAME
    end

    # Builds a source for one review run; nothing is executed until {#call}.
    #
    # @param config [Thingie::Configuration] full merged configuration (`[claude_code]` section)
    # @param changeset [Thingie::Changeset] the files under review; the CLI runs in its workdir
    # @param prompt_builder [Thingie::PromptBuilder] renders the instruction handed to the CLI
    # @param usage [Thingie::Stats::Usage] accumulator fed the run's tokens and cost
    # @param runner [#call] `(argv, chdir:, stdin:, timeout:) -> [stdout, stderr, status]`;
    #   defaults to running the command with Open3, injectable so specs never spawn the CLI
    def initialize(config:, changeset:, prompt_builder:, usage:, runner: nil)
      @settings = DEFAULT_SETTINGS.merge((config['claude_code'] || {}).transform_keys(&:to_s))
      @changeset = changeset
      @prompt_builder = prompt_builder
      @usage = usage
      @runner = runner || method(:run_command)
      @details = { 'source' => SOURCE_NAME }
    end

    # Run metadata for the report's details block: skill, model, turns,
    # duration, cost, session id and the CLI's own written review (`notes`).
    # Empty until {#call} has run.
    #
    # @return [Hash{String=>Object}] run metadata
    attr_reader :details

    # The Claude model the run reported, or the configured one, for the report's `model` field.
    #
    # @return [String] model name
    def model
      @details['model'] || @settings['model'] || SOURCE_NAME
    end

    # Run the CLI once over the changeset and parse its structured findings.
    #
    # @return [Array<Thingie::Issue>] findings parsed per file, ids unassigned
    # @raise [RuntimeError] when the CLI exits non-zero or returns no structured output
    def call
      stdout, stderr, status = @runner.call(argv, chdir: @changeset.workdir, stdin: prompt,
                                                  timeout: @settings['timeout'])
      save_raw_output(stdout)
      raise "#{@settings['command']} exited #{status.exitstatus}: #{stderr.to_s.strip[0, 500]}" unless status.success?

      result = JSON.parse(stdout)
      record_usage(result)
      record_details(result)
      parse_issues(result['structured_output'])
    end

    private

    def argv
      args = [@settings['command'], '-p', '--output-format', 'json', '--json-schema', JSON.generate(SCHEMA),
              '--max-budget-usd', @settings['max_budget_usd'].to_s,
              '--permission-mode', 'dontAsk']
      args.push('--model', @settings['model']) if @settings['model']
      args.push('--max-turns', @settings['max_turns'].to_s) if @settings['max_turns']
      tools = Array(@settings['allowed_tools'])
      args.push('--allowedTools', tools.join(',')) unless tools.empty?
      args
    end

    def prompt
      @prompt_builder.claude_code(skill: @settings['skill'], base_ref: @changeset.base_ref,
                                  head_ref: @changeset.head_ref, files: @changeset.files)
    end

    def run_command(argv, chdir:, stdin:, timeout:)
      Open3.capture3(*argv, stdin_data: stdin, chdir: chdir, timeout: timeout)
    end

    # The full JSON result is the "why did it say this" artifact: keep it on
    # disk (the CI workflow uploads it) rather than in the PR comment.
    def save_raw_output(stdout)
      path = @settings['raw_output_file'].to_s
      return if path.empty? || stdout.to_s.empty?

      path = File.expand_path(path, @changeset.workdir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, stdout)
    rescue SystemCallError => e
      warn "[thingie] could not write #{path}: #{e.message}"
    end

    def record_details(result)
      @details = {
        'source' => SOURCE_NAME,
        'skill' => @settings['skill'],
        'model' => result['modelUsage']&.keys&.first || @settings['model'],
        'turns' => result['num_turns'],
        'duration_ms' => result['duration_ms'],
        'cost_usd' => result['total_cost_usd'],
        'session_id' => result['session_id'],
        'notes' => result['result'].to_s[0, NOTES_LIMIT]
      }.compact
    end

    def record_usage(result)
      usage = result['usage'] || {}
      @usage.record_totals(
        input_tokens: usage['input_tokens'], output_tokens: usage['output_tokens'],
        cache_read_tokens: usage['cache_read_input_tokens'], cache_write_tokens: usage['cache_creation_input_tokens'],
        cost: result['total_cost_usd']
      )
    end

    # The CLI's own output becomes `structured_output`; a missing one means the
    # run ended before producing findings (budget, max turns), which must not
    # pass as a clean empty review.
    def parse_issues(output)
      raise 'claude returned no structured output (budget or turn limit reached?)' unless output.is_a?(Hash)

      by_file = Array(output['issues']).group_by { |issue| issue['file'] }
      parser = IssueParser.new
      by_file.flat_map { |file, issues| parser.parse(issues, file) }
    end
  end
end
