# frozen_string_literal: true

require 'fileutils'
require 'json'

module Thingie
  # Gathers first-pass findings from a headless Claude Code run instead of
  # Thingie's own per-file LLM review. The CLI runs a project skill (by default
  # `/code-review`) over the whole changeset in the reviewed repo, so it reads
  # the project's `.claude/` skills and rules itself; everything downstream
  # (thresholds, code enrichment, the critic pass, the report and PR comments)
  # is unchanged. Selected with `[review] source = "claude_code"` or
  # `REVIEW_SOURCE=claude_code`. Settings come from the `[claude_code]` table,
  # whose defaults live in `config/default.toml`.
  class ClaudeCodeSource
    SOURCE_NAME = 'claude_code'

    # Flat variant of ISSUE_SCHEMA: one run covers every file, so each finding
    # carries its own repo-relative path.
    item = Schemas::ISSUE_SCHEMA[:schema][:properties][:issues][:items]
    item = item.merge(properties: item[:properties].merge(file: { type: 'string' }),
                      required: item[:required] + %w[file])
    SCHEMA = { type: 'object', properties: { issues: { type: 'array', items: item } }, required: %w[issues],
               additionalProperties: false }.freeze

    # Whether the configuration selects this source for the first pass. A blank
    # `REVIEW_SOURCE` (what a workflow sets on a non-escalated run) means unset,
    # as for Thingie's other env overrides.
    #
    # @param config [Thingie::Configuration] the loaded configuration
    # @return [Boolean] true when `REVIEW_SOURCE` or `[review] source` is `claude_code`
    def self.selected?(config)
      source = Env['REVIEW_SOURCE'].to_s.strip
      source = config.dig('review', 'source').to_s if source.empty?
      source.strip.downcase == SOURCE_NAME
    end

    # Builds a source for one review run; nothing is executed until {#call}.
    #
    # @param config [Thingie::Configuration] full merged configuration (`[claude_code]` section)
    # @param changeset [Thingie::Changeset] the files under review; the CLI runs in its workdir
    # @param prompt_builder [Thingie::PromptBuilder] renders the instruction handed to the CLI
    # @param usage [Thingie::Stats::Usage] accumulator fed the run's tokens and cost
    # @param runner [#call] `(argv, chdir:, stdin:, timeout:) -> [stdout, stderr, status]`;
    #   defaults to {ClaudeCodeRunner}, injectable so specs never spawn the CLI
    def initialize(config:, changeset:, prompt_builder:, usage:, runner: ClaudeCodeRunner)
      @settings = (config['claude_code'] || {}).transform_keys(&:to_s)
      # TOML has no nil, so an unset model arrives as "".
      @settings['model'] = nil if @settings['model'].to_s.strip.empty?
      @changeset = changeset
      @prompt_builder = prompt_builder
      @usage = usage
      @runner = runner
      @details = { 'source' => SOURCE_NAME }
      @warnings = []
    end

    # Run metadata for the report's details block: skill, model, turns,
    # duration, cost, session id and the CLI's own written review (`notes`).
    # Only `source` until {#call} has run.
    #
    # @return [Hash{String=>Object}] run metadata
    attr_reader :details

    # Non-fatal problems with the run's output (findings on unknown paths,
    # malformed findings), for the report's processing warnings.
    #
    # @return [Array<String>] warnings
    attr_reader :warnings

    # The model the run reported (the one that spent the most), else the
    # configured one, else `claude_code` when neither is known.
    #
    # @return [String] model name
    def model
      @details['model'] || @settings['model'] || SOURCE_NAME
    end

    # Run the CLI once over the changeset and parse its structured findings.
    #
    # @return [Array<Thingie::Issue>] findings parsed per file, ids unassigned
    # @raise [RuntimeError] when the CLI exits non-zero, times out, prints no JSON,
    #   returns no structured output, or echoes a secret from its environment
    def call
      stdout, stderr, status = @runner.call(argv, chdir: @changeset.workdir, stdin: prompt,
                                                  timeout: @settings['timeout'])
      raw_path = save_raw_output(stdout)
      result = JsonExtractor.parse(stdout.to_s)
      raise "#{command} exited #{status.exitstatus}: #{failure_reason(result, stderr)}" unless status.success?
      raise "#{command} printed no JSON result#{" (saved to #{raw_path})" if raw_path}" unless result.is_a?(Hash)

      reject_leaked_secrets(stdout)
      record_usage(result)
      record_details(result)
      parse_issues(result['structured_output'])
    end

    private

    def command
      @settings['command'].to_s
    end

    # The CLI reports its own failures (auth, API errors) as the JSON result on
    # stdout, with nothing on stderr.
    def failure_reason(result, stderr)
      text = result.is_a?(Hash) ? result['result'].to_s : ''
      (text.strip.empty? ? stderr.to_s : text).strip[0, 500]
    end

    def argv
      args = [command, '-p', '--output-format', 'json', '--json-schema', JSON.generate(SCHEMA),
              '--max-budget-usd', @settings['max_budget_usd'].to_s,
              '--permission-mode', 'dontAsk']
      args.push('--model', @settings['model']) if @settings['model']
      denied = Array(@settings['disallowed_tools'])
      args.push('--disallowedTools', denied.join(',')) unless denied.empty?
      tools = Array(@settings['allowed_tools'])
      args.push('--allowedTools', tools.join(',')) unless tools.empty?
      args
    end

    def prompt
      @prompt_builder.claude_code(skill: @settings['skill'], base_ref: @changeset.base_ref,
                                  head_ref: @changeset.head_ref, files: @changeset.files)
    end

    # The CLI's own output is the one channel back to the PR, so refuse to post
    # anything that echoes a credential from its environment.
    def reject_leaked_secrets(stdout)
      leaked = ClaudeCodeRunner.leaked_secrets(stdout)
      raise "#{command} output contains the value of #{leaked.join(', ')}; refusing to use it" if leaked.any?
    end

    # The full JSON result is the "why did it say this" artifact: keep it on
    # disk (the CI workflow uploads it) rather than in the PR comment.
    #
    # @return [String, nil] the path written, or nil when disabled or it failed
    def save_raw_output(stdout)
      path = @settings['raw_output_file'].to_s
      return if path.empty? || stdout.to_s.empty?

      root = File.join(@changeset.workdir, '')
      path = File.expand_path(path, root)
      raise "raw_output_file must be inside the project: #{path}" unless path.start_with?(root)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, stdout)
      path
    rescue SystemCallError => e
      warn "[thingie] could not write #{path}: #{e.message}"
      nil
    end

    def record_details(result)
      @details = {
        'source' => SOURCE_NAME,
        'skill' => @settings['skill'],
        'model' => reported_model(result) || @settings['model'],
        'turns' => result['num_turns'],
        'duration_ms' => result['duration_ms'],
        'cost_usd' => result['total_cost_usd'],
        'session_id' => result['session_id'],
        'notes' => result['result'].to_s[0, 4000]
      }.compact
    end

    # Subagents may run on other models; name the one that did most of the work.
    def reported_model(result)
      usage = result['modelUsage']
      return unless usage.is_a?(Hash) && usage.any?

      usage.max_by { |_, counts| counts.is_a?(Hash) ? counts['costUSD'].to_f : 0 }.first
    end

    def record_usage(result)
      usage = result['usage'] || {}
      @usage.record_totals(input_tokens: usage['input_tokens'], output_tokens: usage['output_tokens'],
                           cache_read_tokens: usage['cache_read_input_tokens'],
                           cache_write_tokens: usage['cache_creation_input_tokens'], cost: result['total_cost_usd'])
    end

    # The CLI's own output becomes `structured_output`; a missing one means the
    # run ended before producing findings (budget, max turns), which must not
    # pass as a clean empty review. A finding on a path outside the changeset
    # or missing a required field is dropped with a warning rather than
    # discarding the whole (paid) run.
    def parse_issues(output)
      raise "#{command} returned no structured output (budget or turn limit reached?)" unless output.is_a?(Hash)

      parser = IssueParser.new
      Array(output['issues']).group_by { |issue| issue['file'].to_s.delete_prefix('./') }.flat_map do |file, issues|
        next unknown_path(file, issues) unless @changeset.files.include?(file)

        issues.filter_map { |issue| parse_issue(parser, issue, file) }
      end
    end

    def unknown_path(file, issues)
      @warnings << "Claude Code reported #{issues.size} finding(s) for `#{file}`, " \
                   'which is not in the changeset; dropped'
      []
    end

    def parse_issue(parser, issue, file)
      parser.parse(issue, file).first
    rescue KeyError, TypeError => e
      @warnings << "Dropped a malformed Claude Code finding for #{file}: #{e.message}"
      nil
    end
  end
end
