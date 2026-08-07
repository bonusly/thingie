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

  def review_target(commit_sha: 'abc123', branch: 'feat')
    Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: commit_sha,
                              branch: branch, base_ref: 'main', head_ref: 'HEAD', merge_base: false)
  end

  def issue(severity:, tags: [])
    raw = Thingie::RawIssue.new(title: 'T', severity: severity, confidence: 1, details: 'd', tags: tags)
    Thingie::Issue.new(id: 1, file: 'a.rb', raw_issue: raw, affected_lines: [])
  end

  def report(issues: [])
    Thingie::Report.new(target: review_target, model: 'gpt-test', issues: issues,
                        number_of_processed_files: 2)
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
      emitter.emit('review.completed', 'total_issues' => 0)
      expect(File.exist?(sink_path)).to be(false)
    end

    describe '#emit_review_completed' do
      it 'writes the full schema with usage, severity, and tag breakdowns' do
        emitter = described_class.new(config('stats' => stats_config))
        usage = Thingie::Stats::Usage.new
        usage.record(instance_double(RubyLLM::Message, input_tokens: 100, output_tokens: 50,
                                                       cache_read_tokens: nil, cache_write_tokens: nil,
                                                       cost: instance_double(RubyLLM::Cost, total: 0.001)))
        issues = [issue(severity: 1, tags: ['bug']), issue(severity: 2, tags: %w[bug security])]

        emitter.emit_review_completed(report: report(issues: issues), duration_ms: 1234, usage: usage)

        event = read_events.first
        expect(event['event']).to eq('review.completed')
        expect(event['commit_sha']).to eq('abc123')
        expect(event['branch']).to eq('feat')
        expect(event['model']).to eq('gpt-test')
        expect(event['files_reviewed']).to eq(2)
        expect(event['total_issues']).to eq(2)
        expect(event['issues_by_severity']).to eq('1' => 1, '2' => 1)
        expect(event['issues_by_tag']).to eq('bug' => 2, 'security' => 1)
        expect(event['duration_ms']).to eq(1234)
        expect(event['usage']['input_tokens']).to eq(100)
        expect(event['usage']['cost_usd']).to be_within(1e-9).of(0.001)
        expect(event['timestamp']).to match(/^\d{4}-\d{2}-\d{2}T/)
        expect(event['thingie_version']).to eq(Thingie::VERSION)
      end
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
        emitter.emit('review.completed', 'total_issues' => 0)
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

      emitter.emit('review.completed', 'total_issues' => 0)

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

      emitter.emit('review.completed', 'total_issues' => 0)

      expect(File.readlines(sink_path).size).to eq(1)
    ensure
      Thingie::Stats.instance_variable_get(:@sink_types)&.delete('fake')
      $LOADED_FEATURES.reject! { |p| p == plugin_path }
    end
  end
end
