# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'
require 'fileutils'
require 'json'

RSpec.describe Thingie::Stats::CommandSink do
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  def sink(config, root = tmp_dir)
    described_class.new(config: config, root: root)
  end

  it 'pipes one JSON line per emit to the command stdin' do
    output = File.join(tmp_dir, 'captured.jsonl')
    jsonl = sink('command' => "cat > #{Shellwords.escape(output)}")

    jsonl.emit('event' => 'review.completed', 'total_issues' => 2)
    jsonl.emit('event' => 'approval.decided', 'action' => 'block')
    # `cat` writes on EOF, so close the pipe and wait for the child to finish.
    io = jsonl.instance_variable_get(:@io)
    pid = io&.pid
    io&.close
    begin
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil
    end

    lines = File.readlines(output)
    expect(lines.size).to eq(2)
    expect(JSON.parse(lines.first)).to eq('event' => 'review.completed', 'total_issues' => 2)
  end

  context 'when the command cannot run' do
    it 'warns and disables itself without raising' do
      jsonl = sink('command' => '/no/such/binary/here')

      expect { jsonl.emit('event' => 'review.completed') }
        .to output(/Stats command sink '.*' failed — disabling/).to_stderr

      # Subsequent emits are silent no-ops (no further warnings).
      expect { jsonl.emit('event' => 'second') }.not_to output.to_stderr
    end
  end

  context 'when the command config is missing or blank' do
    it 'raises ArgumentError for a missing command' do
      expect { sink({}) }.to raise_error(ArgumentError, /non-blank "command"/)
    end

    it 'raises ArgumentError for a blank command' do
      expect { sink('command' => '  ') }.to raise_error(ArgumentError, /non-blank "command"/)
    end
  end
end
