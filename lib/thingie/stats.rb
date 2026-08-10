# frozen_string_literal: true

module Thingie
  # Stats logging interface: emits machine-readable events after each review
  # and auto-approval decision so admins can build dashboards (Datadog, Logstash,
  # …). Disabled unless `[stats] enabled = true` and at least one
  # `[[stats.sinks]]` destination is configured. Sink failures are fail-open
  # (warn + continue), mirroring the Approver's philosophy — a stats outage
  # never fails a review.
  module Stats
    # Register a sink class under a `type` name so it can be resolved from a
    # `[[stats.sinks]]` `type = "..."` entry. Any gem can call this to add a
    # custom sink; set the entry's `require` to load the gem before lookup.
    #
    # @param type [String, Symbol] the sink type name (stored as a string)
    # @param klass [Class] a class implementing the sink contract
    # @return [void]
    def self.register_sink(type, klass)
      (@sink_types ||= {})[type.to_s] = klass
      nil
    end

    # Look up a previously registered sink class by type name.
    #
    # @param type [String, Symbol] the sink type name
    # @return [Class, nil] the registered class, or nil when unknown
    def self.sink_class(type)
      @sink_types&.[](type.to_s)
    end

    # The sink plugin contract. A sink class implements:
    #
    #   - `initialize(config:, root:)` — `config` is the sink's own TOML hash
    #     (string keys); `root` is the project root for resolving relative
    #     paths. Raise `ArgumentError` on a missing required key.
    #   - `emit(event)` — `event` is a fully-formed, string-keyed event Hash;
    #     serialize/ship it. Must not raise into the caller (the Emitter wraps
    #     each sink in a rescue, but sinks should fail open on their own).
    #
    # Built-in sinks: {JsonlSink} (type `"jsonl"`), {CommandSink} (type
    # `"command"`).
  end
end

require_relative 'stats/usage'
require_relative 'stats/jsonl_sink'
require_relative 'stats/command_sink'
require_relative 'stats/events'
require_relative 'stats/emitter'

Thingie::Stats.register_sink('jsonl', Thingie::Stats::JsonlSink)
Thingie::Stats.register_sink('command', Thingie::Stats::CommandSink)
