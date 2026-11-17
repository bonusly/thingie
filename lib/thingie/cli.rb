# frozen_string_literal: true

require 'thor'
require 'thingie'
require 'thingie/version'

module Thingie
  # Thor-based CLI for thingie: `approve` and `version`.
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

    desc 'approve', 'Approve the PR when Copilot approved its current commit and every rule passes'
    option :pr, type: :numeric, desc: 'Pull Request number'
    option :gh_repo, type: :string, desc: 'owner/repo'
    option :token, type: :string, desc: 'GitHub token'
    option :resolve_token, type: :string,
                           desc: 'Fallback token for approving and dismissing (PAT; falls back to main token)'
    # Evaluates the approval rules and approves, dismisses, or explains on the PR.
    # Does nothing unless `[approve] enabled = true`.
    #
    # @return [void]
    def approve
      config = Thingie::Configuration.new
      settings = config['approve']
      return unless settings.is_a?(Hash) && settings['enabled']

      debug "Approve enabled: yes#{' (dry run)' if settings['dry_run']}"
      context = resolve_github_context
      decision = build_approver(context, settings).run
      emit_approval_stats(config, context, settings, decision) if decision
    rescue StandardError => e
      warn "Approval failed: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if debug_enabled?
      exit 1
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
        cmd.options.each_value { |opt| shell.say option_line(opt) }
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

      # Only read the GitHub Actions environment when the caller hasn't supplied
      # the repo and PR explicitly, so manual/local runs aren't forced through it.
      #
      # @return [Thingie::GitHub::Context, nil] the resolved context, or nil when unneeded
      def resolve_github_context
        return nil if options[:gh_repo] && options[:pr]

        Thingie::GitHub::Context.from_env
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

      # @param context [Thingie::GitHub::Context, nil] the resolved GitHub Action context
      # @param approve_config [Hash] the `[approve]` config section
      # @return [Thingie::GitHub::Approver] the configured approver
      def build_approver(context, approve_config)
        Thingie::GitHub::Approver.new(
          token: options[:token] || Env.fetch('GITHUB_TOKEN', nil),
          resolve_token: options[:resolve_token] || Env.fetch('THINGIE_RESOLVE_TOKEN', nil),
          owner: repo_owner(context),
          repo: repo_name(context),
          pr_number: options[:pr] || context&.pr_number,
          config: approve_config
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

      # @param message [String] the line to print when debug logging is on
      # @return [void]
      def debug(message)
        warn "[DEBUG] #{message}" if debug_enabled?
      end
    end
  end
end
