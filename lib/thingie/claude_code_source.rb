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
      # `--json-schema` only works with models the CLI knows; for anything else
      # the JSON is asked for in the prompt and read back out of the result text.
      @provider = config['provider']
      @models_file = config['models_file']
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
      diff_path = write_project_file(@settings['diff_file'], @changeset.patch_text)
      stdout, stderr, status = @runner.call(argv, chdir: @changeset.workdir, stdin: prompt(diff_path),
                                                  timeout: @settings['timeout'])
      raw_path = write_project_file(@settings['raw_output_file'], stdout)
      transcript = ClaudeCodeTranscript.parse(stdout)
      result = transcript.result
      raise "#{command} exited #{status.exitstatus}: #{transcript.failure_reason(stderr)}" unless status.success?
      raise "#{command} printed no JSON result#{" (saved to #{raw_path})" if raw_path}" unless result.is_a?(Hash)

      ClaudeCodeRunner.reject_leaked_secrets!(stdout, command)
      record_usage(result)
      record_details(result, transcript)
      parse_issues(structured_output? ? result['structured_output'] : JsonExtractor.parse(result['result'].to_s))
    end

    private

    def command
      @settings['command'].to_s
    end

    def argv
      args = [command, '-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', 'dontAsk']
      args.push('--json-schema', JSON.generate(SCHEMA)) if structured_output?
      args.push('--max-budget-usd', @settings['max_budget_usd'].to_s) if @settings['max_budget_usd'].to_f.positive?
      args.push('--max-turns', @settings['max_turns'].to_s) if @settings['max_turns'].to_i.positive?
      args.push('--model', @settings['model']) if @settings['model']
      denied = Array(@settings['disallowed_tools'])
      args.push('--disallowedTools', denied.join(',')) unless denied.empty?
      tools = Array(@settings['allowed_tools'])
      tools.empty? ? args : args.push('--allowedTools', tools.join(','))
    end

    # The diff is a file so the run needs no shell (an agent's `git diff` rarely matches an allow rule).
    def prompt(diff_path)
      @prompt_builder.claude_code(skill: @settings['skill'], base_ref: @changeset.base_ref,
                                  head_ref: @changeset.head_ref, files: @changeset.files,
                                  diff_path: diff_path&.delete_prefix(File.join(@changeset.workdir, '')),
                                  inline_json: !structured_output?)
    end

    def structured_output? = @settings.fetch('structured_output', true)

    # Writes a run file (the diff handed to the agent, the transcript kept as
    # the "why did it say this" artifact) inside the project.
    #
    # @return [String, nil] the absolute path written, or nil when disabled or it failed
    def write_project_file(setting, content)
      path = setting.to_s
      return if path.empty? || content.to_s.empty?

      root = File.join(@changeset.workdir, '')
      path = File.expand_path(path, root)
      raise "#{path} is outside the project; run files must be inside it" unless path.start_with?(root)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    rescue SystemCallError => e
      warn "[thingie] could not write #{path}: #{e.message}"
      nil
    end

    def record_details(result, transcript)
      @details = {
        'source' => SOURCE_NAME,
        'skill' => @settings['skill'],
        'model' => reported_model(result) || @settings['model'],
        'turns' => result['num_turns'],
        'subagents' => transcript.subagents,
        'tool_calls' => transcript.tool_calls,
        'duration_ms' => result['duration_ms'],
        'cost_usd' => @cost,
        'cost_source' => @cost_source,
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
      @cost, @cost_source = ClaudeCodePricing.cost(result, model: reported_model(result) || @settings['model'],
                                                           provider: @provider, models_file: @models_file)
      @usage.record_totals(input_tokens: usage['input_tokens'], output_tokens: usage['output_tokens'],
                           cache_read_tokens: usage['cache_read_input_tokens'],
                           cache_write_tokens: usage['cache_creation_input_tokens'], cost: @cost)
    end

    # A run that ends without the findings JSON (budget, turn cap, model went
    # off-script) must not pass as a clean empty review. A finding on a path
    # outside the changeset or missing a required field is dropped with a
    # warning rather than discarding the whole (paid) run.
    def parse_issues(output)
      output = { 'issues' => output } if output.is_a?(Array)
      raise "#{command} returned no findings JSON (budget or turn limit reached?)" unless output.is_a?(Hash)

      parser = IssueParser.new
      Array(output['issues']).group_by { |issue| issue['file'].to_s.delete_prefix('./') }.flat_map do |file, issues|
        next issues.filter_map { |issue| parse_issue(parser, issue, file) } if @changeset.files.include?(file)

        @warnings << "Claude Code reported #{issues.size} finding(s) for `#{file}`, not in the changeset; dropped"
        []
      end
    end

    def parse_issue(parser, issue, file)
      parser.parse(issue, file).first
    rescue KeyError, TypeError => e
      @warnings << "Dropped a malformed Claude Code finding for #{file}: #{e.message}"
      nil
    end
  end
end
