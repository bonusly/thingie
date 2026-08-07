# frozen_string_literal: true

require 'time'

module Thingie
  module Stats
    # Emits structured stats events to all configured sinks. Disabled unless
    # `[stats] enabled = true` and at least one `[[stats.sinks]]` entry exists.
    # Sink construction is lazy and memoized; each sink dispatch is isolated so
    # one failing sink never silences the others.
    class Emitter
      # Builds an emitter for a resolved run configuration.
      #
      # @param config [Thingie::Configuration] the loaded configuration
      def initialize(config)
        @config = config
      end

      # Whether stats emission is active: the `[stats]` section is a Hash,
      # `enabled` is truthy, and at least one `[[stats.sinks]]` entry exists.
      #
      # @return [Boolean] whether emission is enabled
      def enabled?
        stats = @config['stats']
        stats.is_a?(Hash) && stats['enabled'] && Array(stats['sinks']).any?(Hash)
      end

      # Emits a single event to every configured sink. No-op when disabled.
      # Each sink dispatch is isolated so one failing sink never silences the
      # rest. Explicit `fields` override the common/env-derived fields; nil
      # values in `fields` are dropped before merging.
      #
      # @param name [String] the event name, set under the `"event"` key
      # @param fields [Hash{String=>Object}] event-specific fields
      # @return [void]
      def emit(name, fields = {})
        return unless enabled?

        event = common_fields.merge(fields.compact)
        event['event'] = name
        sinks.each { |sink| safe_emit(sink, event) }
      end

      # Emits the `review.completed` event carrying the run's report summary
      # and accumulated LLM usage.
      #
      # @param report [Thingie::Report] the finished review report
      # @param duration_ms [Integer] wall-clock review duration in milliseconds
      # @param usage [Thingie::Stats::Usage] accumulated LLM usage for the run
      # @return [void]
      def emit_review_completed(report:, duration_ms:, usage:)
        emit('review.completed', Events.review_completed(report, duration_ms, usage))
      end

      # Emits the `approval.decided` event carrying the approver's action and
      # block reasons. Explicit `repo`/`pr_number` override env-derived values.
      #
      # @param action [Symbol] `:approve`, `:block`, or `:skip`
      # @param reasons [Array<String>] block reasons (empty for approve/skip)
      # @param repo [String, nil] the `owner/repo` slug
      # @param pr_number [Integer, nil] the pull request number
      # @param dry_run [Boolean] whether approval is in dry-run mode
      # @return [void]
      def emit_approval_decided(action:, reasons:, repo:, pr_number:, dry_run:)
        emit('approval.decided', Events.approval_decided(action: action, reasons: reasons, repo: repo,
                                                         pr_number: pr_number, dry_run: dry_run))
      end

      private

      def common_fields
        fields = { 'timestamp' => Time.now.iso8601, 'thingie_version' => Thingie::VERSION }
        fields.merge!(github_enrichment)
        tags = stats_tags
        fields['tags'] = tags if tags
        fields
      end

      def github_enrichment
        @github_enrichment ||=
          begin
            ctx = Thingie::GitHub::Context.from_env
            { 'repo' => ctx.repo, 'pr_number' => ctx.pr_number }.compact
          rescue StandardError
            {}
          end
      end

      def stats_tags
        tags = @config.dig('stats', 'tags')
        tags.is_a?(Hash) && !tags.empty? ? tags : nil
      end

      def sinks
        @sinks ||= Array(@config.dig('stats', 'sinks')).filter_map { |entry| build_sink(entry) }
      end

      def build_sink(entry)
        return unless entry.is_a?(Hash) && entry['type'] && plugin_loaded?(entry)

        klass = Thingie::Stats.sink_class(entry['type'])
        return warn_unknown(entry['type']) unless klass

        klass.new(config: entry, root: @config.root)
      rescue StandardError => e
        warn "Stats sink failed to initialize — #{e.class}: #{e.message}"
        nil
      end

      def load_plugin(name)
        require name
        true
      rescue LoadError => e
        warn "Could not load stats sink plugin '#{name}' — #{e.message}"
        false
      end

      def plugin_loaded?(entry)
        return true unless entry['require']

        load_plugin(entry['require'])
      end

      def warn_unknown(type)
        warn "Unknown stats sink type '#{type}' — skipped."
        nil
      end

      def safe_emit(sink, event)
        sink.emit(event)
      rescue StandardError => e
        warn "Stats sink failed — #{e.class}: #{e.message}"
      end
    end
  end
end
