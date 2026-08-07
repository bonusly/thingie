# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Thingie::Stats::JsonlSink do
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  def sink(config, root = tmp_dir)
    described_class.new(config: config, root: root)
  end

  it 'appends one JSON line per emit to the file' do
    path = File.join(tmp_dir, 'stats.jsonl')
    jsonl = sink('path' => path)

    jsonl.emit('event' => 'review.completed', 'total_issues' => 0)
    jsonl.emit('event' => 'approval.decided', 'action' => 'approve')

    lines = File.readlines(path)
    expect(lines.size).to eq(2)
    expect(JSON.parse(lines.first)).to eq('event' => 'review.completed', 'total_issues' => 0)
    expect(JSON.parse(lines.last)).to eq('event' => 'approval.decided', 'action' => 'approve')
  end

  it 'creates parent directories when missing' do
    path = File.join(tmp_dir, 'nested', 'deep', 'stats.jsonl')
    jsonl = sink('path' => path)

    jsonl.emit('event' => 'review.completed')

    expect(File.exist?(path)).to be(true)
    expect(File.readlines(path).size).to eq(1)
  end

  it 'expands relative paths against root' do
    jsonl = sink({ 'path' => 'relative/stats.jsonl' }, tmp_dir)

    jsonl.emit('event' => 'review.completed')

    expect(File.exist?(File.join(tmp_dir, 'relative', 'stats.jsonl'))).to be(true)
  end

  context 'when path is "stdout"' do
    it 'writes JSON lines to $stdout' do
      jsonl = sink('path' => 'stdout')

      expect do
        jsonl.emit('event' => 'review.completed')
      end.to output(/^\{"event":"review.completed"\}\n$/).to_stdout
    end
  end

  context 'when path is missing or blank' do
    it 'raises ArgumentError for a missing path' do
      expect { sink({}) }.to raise_error(ArgumentError, /non-blank "path"/)
    end

    it 'raises ArgumentError for a blank path' do
      expect { sink('path' => '  ') }.to raise_error(ArgumentError, /non-blank "path"/)
    end
  end
end
