# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'thingie'
require 'thingie/version'

module Thingie
  # Thor-based CLI for thingie. Mirrors the command structure of Gito where possible:
  # review, report, files, github-comment, setup.
  # rubocop:disable Metrics/ClassLength
  class CLI < Thor
    class_option :debug, type: :boolean, default: false,
                         desc: 'Enable debug logging (also: THINGIE_DEBUG env var)'

    desc 'version', 'Show thingie version'
    # Prints the installed thingie version.
    #
    # @return [void]
    def version
      puts Thingie::VERSION
    end

    # Overrides the default help output to also list each command's options,
    # so `thingie --help` shows what flags each command accepts.
    #
    # @param command [String, nil] optional command name to show detailed help for
    # @param subcommand [Boolean] whether `command` is a subcommand (passed through to Thor)
    # @return [void]
    def help(command = nil, subcommand = false) # rubocop:disable Style/OptionalBooleanParameter
      return super if command

      shell.say 'Commands:'
      self.class.commands.reject { |_, c| c.hidden? }.sort.each do |name, cmd|
        print_command_help(name, cmd)
      end
    end

    no_commands do
      # Prints a command's name, description, and options to the shell.
      #
      # @param name [String, Symbol] command name
      # @param cmd [Thor::Command] the Thor command object
      # @return [void]
      def print_command_help(name, cmd)
        shell.say "  #{name}"
        shell.say "    #{cmd.description}" if cmd.description && !cmd.description.empty?
        print_command_options(cmd)
      end

      # Prints each of a command's options, one per line.
      #
      # @param cmd [Thor::Command] the Thor command object
      # @return [void]
      def print_command_options(cmd)
        opts = cmd.options.values
        return if opts.empty?

        opts.each { |opt| shell.say option_line(opt) }
      end

      # Formats a single command option as a `--flag, alias  # description` line.
      #
      # @param opt [Thor::Option] the option to format
      # @return [String] the formatted option line
      def option_line(opt)
        switches = ["--#{opt.name.tr('_', '-')}"]
        switches.concat(Array(opt.aliases).map(&:to_s))
        line = "    #{switches.join(', ').ljust(28)}# #{opt.description}"
        return line if opt.default.nil?

        "#{line} (Default: #{opt.default.inspect})"
      end
    end

    desc 'review', 'Perform a code review of the target codebase changes'
    option :what, type: :string, aliases: '-w', desc: 'Git ref to review'
    option :against, type: :string, aliases: '-v', desc: 'Git ref to compare against'
    option :filters, type: :string, aliases: '-f', desc: 'Filter reviewed files by glob pattern(s)'
    option :merge_base, type: :boolean, default: true, desc: 'Use merge base for comparison'
    option :output, type: :string, aliases: '-o', desc: 'Output folder for the review report'
    option :all, type: :boolean, default: false, desc: 'Review whole codebase'
    option :model, type: :string, aliases: '-m', desc: 'LLM model to use for the review'
    option :provider, type: :string, aliases: '-p', desc: 'LLM provider to use (e.g. openai, anthropic)'
    # Performs a code review of the target codebase changes and renders the report.
    #
    # @return [void]
    def review(*)
      # Thor passes positional args we don't use; accept and ignore them.
      config = Thingie::Configuration.new(overrides: { model: options[:model], provider: options[:provider] }.compact)
      changeset = build_changeset(config)
      clients = build_lsp_clients(config, changeset)
      tools = clients.map { |client| Thingie::Lsp::SymbolTool.new(client: client, root: changeset.workdir) }
      tools << Thingie::FileTool.new(root: changeset.workdir)
      skill_tool = Thingie::SkillCatalog.tool(config)
      tools << skill_tool if skill_tool
      mcp_toolset = Thingie::Mcp::Toolset.build(config)
      mcp_toolset.warnings.each { |w| warn "[thingie] #{w}" }
      tools.concat(mcp_toolset.tools)
      reviewer = build_reviewer(config, changeset, tools)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      report = reviewer.review
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      render_report(report, config)
      Thingie::Stats::Emitter.new(config).emit_review_completed(report: report, duration_ms: duration_ms,
                                                                usage: reviewer.usage)
    rescue StandardError => e
      warn "Review failed: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if debug_enabled?
      exit 1
    ensure
      clients&.each(&:shutdown)
      mcp_toolset&.shutdown
    end

    desc 'files', 'List files in the changeset'
    option :what, type: :string, aliases: '-w', desc: 'Git ref to review'
    option :against, type: :string, aliases: '-v', desc: 'Git ref to compare against'
    option :filters, type: :string, aliases: '-f', desc: 'Filter reviewed files by glob pattern(s)'
    option :merge_base, type: :boolean, default: true, desc: 'Use merge base for comparison'
    option :all, type: :boolean, default: false, desc: 'List all tracked files'
    option :diff, type: :boolean, default: false, desc: 'Show diff content'
    # Lists the files in the current changeset.
    #
    # @return [void]
    def files
      changeset = build_changeset
      changeset.files.each { |file| print_file(file, changeset) }
    rescue StandardError => e
      warn "Could not list files: #{e.class}: #{e.message}"
      exit 1
    end

    desc 'report', 'Render a saved code review report'
    option :source, type: :string, aliases: '-s', desc: 'Source JSON report to load'
    option :format, type: :string, default: 'cli', desc: 'Output format (cli, md)'
    # Renders a previously saved code review report.
    #
    # @return [void]
    def report
      source = options[:source] || 'code-review-report.json'
      report = Thingie::Report.from_file(source)
      renderer = Thingie::ReportRenderer.new(report, severity_scale: config_for_report.severity_scale)
      puts options[:format] == 'md' ? renderer.to_md : renderer.to_cli
    rescue StandardError => e
      warn "Could not render report: #{e.message}"
      exit 1
    end

    desc 'dismiss-approvals', 'Dismiss existing Thingie approvals on a PR before reviewing'
    option :pr, type: :numeric, desc: 'Pull Request number'
    option :gh_repo, type: :string, desc: 'owner/repo'
    option :token, type: :string, desc: 'GitHub token'
    option :resolve_token, type: :string,
                           desc: 'Token for dismissing approvals (PAT; falls back to main token)'
    # Dismisses all existing Thingie approvals on the PR. Run this at the start
    # of a review cycle so a stale approval from a prior run can't be used to
    # merge new changes before the current review finishes.
    #
    # @return [void]
    def dismiss_approvals
      context = resolve_github_context
      config = Thingie::Configuration.new
      approve = config['approve']
      return unless approve.is_a?(Hash) && approve['enabled']

      build_approver(context, approve, nil, nil).dismiss_existing_approvals
    rescue StandardError => e
      warn "Could not dismiss approvals: #{e.message}"
      exit 1
    end

    desc 'github-comment', 'Post a code review comment to GitHub'
    option :md_report_file, type: :string, desc: 'Path to the Markdown report'
    option :pr, type: :numeric, desc: 'Pull Request number'
    option :gh_repo, type: :string, desc: 'owner/repo'
    option :token, type: :string, desc: 'GitHub token'
    option :resolve_token, type: :string,
                           desc: 'Token for resolving review threads (PAT/App; GITHUB_TOKEN cannot)'
    # Posts a code review comment to GitHub and optionally auto-approves the PR.
    #
    # @return [void]
    def github_comment
      context = resolve_github_context
      commenter = build_commenter(context)
      summary = File.read(options[:md_report_file] || 'code-review-report.md')
      report = Thingie::Report.from_file(json_path_for(options[:md_report_file]))
      debug_approve_state
      posting_error = post_review_without_raising(commenter, summary, report)
      maybe_approve(context, report, summary)
      exit 1 if posting_error
    rescue StandardError => e
      warn "GitHub comment failed: #{e.message}"
      exit 1
    end

    desc 'models', 'Refresh and save the local RubyLLM models registry'
    option :path, type: :string, aliases: '-p',
                  desc: 'Where to save the models JSON (defaults to the models_file config)'
    # Refreshes and saves the local RubyLLM models registry.
    #
    # @return [void]
    def models
      config = Thingie::Configuration.new
      expanded = resolve_models_path(config)
      FileUtils.mkdir_p(File.dirname(expanded))

      # Point the registry at the target so save_to_json writes there, and so
      # refresh is consistent with the file reviews will load. Apply provider
      # credentials to the global config so refresh can fetch provider model
      # lists in addition to the public models.dev catalog.
      RubyLLM.config.model_registry_file = expanded
      Thingie::LlmClient.apply_provider_config!(RubyLLM.config, config)

      puts 'Refreshing models from configured providers and models.dev...'
      RubyLLM.models.refresh!
      RubyLLM.models.save_to_json(expanded)
      puts "Saved #{RubyLLM.models.count} models to #{expanded}"
    rescue StandardError => e
      warn "Models refresh failed: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if debug_enabled?
      exit 1
    end

    # rubocop:disable Metrics/BlockLength
    no_commands do
      # Resolves the local models JSON path from --path or the `models_file`
      # config. Exits with a usage message when neither is set.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @return [String] the expanded, absolute path to the models JSON file
      def resolve_models_path(config)
        path = options[:path] || config['models_file']
        unless path && !path.to_s.strip.empty?
          warn 'No models_file configured. Set models_file in .thingie/config.toml or pass --path.'
          exit 1
        end
        File.expand_path(path)
      end

      # Builds a `Thingie::Changeset` from the current command's options.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @return [Thingie::Changeset] the computed changeset
      def build_changeset(config = Thingie::Configuration.new)
        Thingie::Changeset.new(
          head_ref: options[:what],
          base_ref: options[:against],
          all: options[:all] || false,
          filters: options[:filters]&.split(','),
          exclude_files: config['exclude_files'],
          # Thor's options hash isn't indifferent for #fetch, so read via [] (it
          # always has a value because the option declares default: true).
          merge_base: options[:merge_base]
        )
      end

      # `report` command has no config overrides of its own; load defaults so
      # the severity scale matches what was used at review time.
      #
      # @return [Thingie::Configuration] a default configuration
      def config_for_report
        Thingie::Configuration.new
      end

      # Builds the `Thingie::Reviewer` that orchestrates the review pipeline.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @param changeset [Thingie::Changeset] the changeset to review
      # @param tools [Array] RubyLLM tools to make available to the LLM
      # @return [Thingie::Reviewer] the configured reviewer
      def build_reviewer(config, changeset, tools = [])
        Thingie::Reviewer.new(
          config: config,
          changeset: changeset,
          prompt_builder: Thingie::PromptBuilder.new(config),
          llm_client: Thingie::LlmClient.new(config),
          tools: tools,
          debug: debug_enabled?
        )
      end

      # One LSP client per configured language whose extensions match a changed
      # file, so we don't spawn a server the review won't use.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @param changeset [Thingie::Changeset] the changeset being reviewed
      # @return [Array<Thingie::Lsp::Client>] one client per relevant language
      def build_lsp_clients(config, changeset)
        servers = config['lsp']
        return [] unless servers.is_a?(Hash) && !servers.empty?

        changed_exts = changeset.files.map { |f| File.extname(f) }
        servers.values.filter_map do |server|
          next unless Array(server['extensions']).intersect?(changed_exts)

          Thingie::Lsp::Client.new(command: server['command'], root: changeset.workdir)
        end
      end

      # Renders and saves the review report to CLI output, Markdown, and JSON.
      #
      # @param report [Thingie::Report] the report to render
      # @param config [Thingie::Configuration] the loaded configuration
      # @return [void]
      def render_report(report, config)
        output = options[:output] || '.'
        renderer = Thingie::ReportRenderer.new(report, severity_scale: config.severity_scale)
        report.save(output)
        File.write(File.join(output, 'code-review-report.md'), renderer.to_md)
        puts renderer.to_cli
      end

      # Prints a single changeset file's path, or its diff when `--diff` is set.
      #
      # @param file [String] path of the file relative to the changeset root
      # @param changeset [Thingie::Changeset] the changeset being listed
      # @return [void]
      def print_file(file, changeset)
        if options[:diff]
          puts "--- #{file} ---"
          puts changeset.diff_text_for(file)
        else
          puts file
        end
      end

      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @return [String, nil] the repository owner, from `--gh-repo` or the context
      def repo_owner(context)
        options[:gh_repo]&.split('/')&.first || context&.owner
      end

      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @return [String, nil] the repository name, from `--gh-repo` or the context
      def repo_name(context)
        options[:gh_repo]&.split('/')&.last || context&.repo_name
      end

      # Derives the JSON report path from the Markdown report path.
      #
      # @param md_path [String, nil] path to the Markdown report file
      # @return [String] path to the corresponding JSON report file
      def json_path_for(md_path)
        return 'code-review-report.json' unless md_path

        ext = File.extname(md_path)
        ext.empty? ? "#{md_path}.json" : md_path.sub(/#{Regexp.escape(ext)}\z/, '.json')
      end

      # Only read the GitHub Actions environment when the caller hasn't supplied
      # the repo and PR explicitly, so manual/local runs aren't forced through it.
      #
      # @return [Thingie::GitHub::Context, nil] the resolved context, or nil when unneeded
      def resolve_github_context
        return nil if options[:gh_repo] && options[:pr]

        Thingie::GitHub::Context.from_env
      end

      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @return [Thingie::GitHub::Commenter] a commenter configured for the target PR
      def build_commenter(context)
        Thingie::GitHub::Commenter.new(
          token: options[:token] || Env.fetch('GITHUB_TOKEN', nil),
          resolve_token: options[:resolve_token] || Env.fetch('THINGIE_RESOLVE_TOKEN', nil),
          owner: repo_owner(context),
          repo: repo_name(context),
          pr_number: options[:pr] || context&.pr_number
        )
      end

      # Auto-approve the PR when the [approve] config block is enabled. Loads
      # config here because github-comment otherwise runs without it.
      #
      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @param report [Thingie::Report] the review report
      # @param summary [String] the Markdown review summary
      # @return [void]
      # Posts the review, returning the failure instead of raising it.
      #
      # The approval gate must be evaluated even when commenting fails. The
      # decision is the control; the comments only explain it. On
      # special_sauce#26652 a rate-limited comment post raised out of this
      # step, `maybe_approve` never ran, and the run finished with no decision
      # anywhere: none on the pull request and no `approval.decided` event in
      # the stats stream. The command still exits non-zero afterwards, so a
      # failed post stays visible as a red check.
      #
      # @param commenter [Thingie::GitHub::Commenter] the configured commenter
      # @param summary [String] the human-readable review summary text
      # @param report [Thingie::Report] the completed review report
      # @return [StandardError, nil] the posting failure, or nil on success
      def post_review_without_raising(commenter, summary, report)
        commenter.post_review(summary: summary, report: report)
        nil
      rescue StandardError => e
        warn "GitHub comment failed: #{e.message}"
        e
      end

      def maybe_approve(context, report, summary)
        config = Thingie::Configuration.new
        approve = config['approve']
        return unless approve.is_a?(Hash) && approve['enabled']

        decision = build_approver(context, approve, summary, approval_llm_client(config)).run(report)
        emit_approval_stats(config, context, approve, decision) if decision
      end

      # Emits the `approval.decided` stats event for an approver decision.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @param approve [Hash] the `[approve]` config section
      # @param decision [Thingie::GitHub::Approver::Decision] the approver's decision
      # @return [void]
      def emit_approval_stats(config, context, approve, decision)
        Thingie::Stats::Emitter.new(config).emit_approval_decided(
          action: decision.action, reasons: decision.reasons,
          repo: [repo_owner(context), repo_name(context)].compact.join('/'),
          pr_number: options[:pr] || context&.pr_number, dry_run: approve['dry_run'] ? true : false
        )
      end

      # Best-effort LLM client for the approval risk assessment. Returns nil when
      # no LLM key is configured (e.g. the github-comment step lacks LLM_API_KEY),
      # so the approval still posts, just without the risk section.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      # @return [Thingie::LlmClient, nil] the client, or nil when unavailable
      def approval_llm_client(config)
        Thingie::LlmClient.new(config)
      rescue StandardError => e
        warn "Approval risk assessment disabled — #{e.message}" if debug_enabled?
        nil
      end

      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @param approve_config [Hash] the `[approve]` config section
      # @param summary [String] the Markdown review summary
      # @param llm_client [Thingie::LlmClient, nil] client for risk assessment, if available
      # @return [Thingie::GitHub::Approver] the configured approver
      def build_approver(context, approve_config, summary, llm_client)
        Thingie::GitHub::Approver.new(
          token: options[:token] || Env.fetch('GITHUB_TOKEN', nil),
          resolve_token: options[:resolve_token] || Env.fetch('THINGIE_RESOLVE_TOKEN', nil),
          owner: repo_owner(context),
          repo: repo_name(context),
          pr_number: options[:pr] || context&.pr_number,
          config: approve_config,
          llm_client: llm_client,
          review_summary: summary
        )
      end

      # Debug is on when --debug is passed OR THINGIE_DEBUG is set to a non-empty,
      # non-false value. Empty string is treated as off so GitHub Actions' default
      # empty-variable expansion doesn't accidentally enable debug on every run.
      #
      # @return [Boolean] whether debug logging is enabled
      def debug_enabled?
        env_val = Env.fetch('THINGIE_DEBUG', nil)
        env_on = env_val && !env_val.strip.empty? && !%w[0 false].include?(env_val.strip.downcase)
        env_on || options[:debug]
      end

      # Mirror maybe_approve's config load so the debug banner reports the same
      # approve state that will actually be evaluated.
      #
      # @return [void]
      def debug_approve_state
        return unless debug_enabled?

        approve = Thingie::Configuration.new['approve']
        enabled = approve.is_a?(Hash) ? approve['enabled'] : false
        warn "[DEBUG] Approve enabled: #{enabled ? 'yes' : 'no'}"
      end
    end
    # rubocop:enable Metrics/BlockLength
    # rubocop:enable Metrics/ClassLength
  end
end
