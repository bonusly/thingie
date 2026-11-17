# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Thingie::Stats::Emitter do
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  def config(overrides = {})
    Thingie::Configuration.new(root: tmp_dir, overrides: overrides)
  end

  describe '#enabled?' do
    it 'is disabled by default' do
      expect(described_class.new(config)).not_to be_enabled
    end

    it 'is disabled when enabled but no sinks are configured' do
      emitter = described_class.new(config('stats' => { 'enabled' => true }))
      expect(emitter).not_to be_enabled
    end

    it 'is enabled when enabled and at least one sink entry exists' do
      emitter = described_class.new(config('stats' => { 'enabled' => true,
                                                        'sinks' => [{ 'type' => 'jsonl',
                                                                      'path' => 'out.jsonl' }] }))
      expect(emitter).to be_enabled
    end
  end

  context 'with a jsonl sink into a tmpdir file' do
    let(:sink_path) { File.join(tmp_dir, 'stats.jsonl') }
    let(:stats_config) do
      { 'enabled' => true, 'sinks' => [{ 'type' => 'jsonl', 'path' => sink_path }] }
    end

    def read_events
      File.readlines(sink_path).map { |line| JSON.parse(line) }
    end

    it 'emits nothing when disabled' do
      emitter = described_class.new(config)
      emitter.emit('approval.decided', 'action' => 'skip')
      expect(File.exist?(sink_path)).to be(false)
    end

    describe '#emit_approval_decided' do
      it 'writes action, reasons, and dry_run with explicit repo/pr override' do
        emitter = described_class.new(config('stats' => stats_config))

        emitter.emit_approval_decided(action: :block, reasons: ['too big', 'critical finding'],
                                      repo: 'org/repo', pr_number: 42, dry_run: true)

        event = read_events.first
        expect(event['event']).to eq('approval.decided')
        expect(event['action']).to eq('block')
        expect(event['reasons']).to eq(['too big', 'critical finding'])
        expect(event['repo']).to eq('org/repo')
        expect(event['pr_number']).to eq(42)
        expect(event['dry_run']).to be(true)
        expect(event['timestamp']).to match(/^\d{4}-\d{2}-\d{2}T/)
        expect(event['thingie_version']).to eq(Thingie::VERSION)
      end

      it 'serializes dry_run as a boolean' do
        emitter = described_class.new(config('stats' => stats_config))

        emitter.emit_approval_decided(action: :approve, reasons: [], repo: 'o/r', pr_number: 1, dry_run: false)

        expect(read_events.first['dry_run']).to be(false)
      end
    end
  end

  context 'with an unknown sink type' do
    it 'warns and skips without raising' do
      stats_config = { 'enabled' => true, 'sinks' => [{ 'type' => 'totally-made-up' }] }
      emitter = described_class.new(config('stats' => stats_config))

      expect do
        emitter.emit('approval.decided', 'action' => 'skip')
      end.to output(/Unknown stats sink type 'totally-made-up' — skipped/).to_stderr
    end
  end

  context 'with a sink that raises on emit' do
    it 'does not stop a second sink from receiving the event' do
      exploding = Class.new do
        def initialize(config:, root:); end

        def emit(_event)
          raise StandardError, 'boom'
        end
      end
      Thingie::Stats.register_sink('exploding', exploding)

      sink_path = File.join(tmp_dir, 'good.jsonl')
      stats_config = { 'enabled' => true,
                       'sinks' => [{ 'type' => 'exploding' },
                                   { 'type' => 'jsonl', 'path' => sink_path }] }
      emitter = described_class.new(config('stats' => stats_config))

      emitter.emit('approval.decided', 'action' => 'skip')

      expect(File.readlines(sink_path).size).to eq(1)
    end
  end

  context 'with a sink type loaded via require' do
    it 'loads the plugin and uses its type' do
      plugin_path = File.join(tmp_dir, 'fake_sink.rb')
      File.write(plugin_path, <<~RUBY)
        require 'json'
        require 'fileutils'

        module FakeSink
          class Sink
            def initialize(config:, root:)
              @path = config['path']
              FileUtils.mkdir_p(File.dirname(@path))
              @io = File.open(@path, 'a')
            end

            def emit(event)
              @io.puts(JSON.generate(event))
              @io.flush
            end
          end
        end

        Thingie::Stats.register_sink('fake', FakeSink::Sink)
      RUBY

      sink_path = File.join(tmp_dir, 'plugin.jsonl')
      require_name = plugin_path.sub(/\.rb\z/, '')
      stats_config = { 'enabled' => true,
                       'sinks' => [{ 'type' => 'fake', 'path' => sink_path,
                                     'require' => require_name }] }
      emitter = described_class.new(config('stats' => stats_config))

      emitter.emit('approval.decided', 'action' => 'skip')

      expect(File.readlines(sink_path).size).to eq(1)
    ensure
      Thingie::Stats.instance_variable_get(:@sink_types)&.delete('fake')
      $LOADED_FEATURES.reject! { |p| p == plugin_path }
    end
  end
end
