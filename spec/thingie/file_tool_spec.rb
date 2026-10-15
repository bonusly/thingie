# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::FileTool do
  subject(:tool) { described_class.new(root: tmp_dir) }

  let(:tmp_dir) { Dir.mktmpdir }
  let(:text_path) { File.join(tmp_dir, 'lib', 'thing.rb') }
  let(:binary_path) { File.join(tmp_dir, 'assets', 'blob.bin') }

  before do
    FileUtils.mkdir_p(File.dirname(text_path))
    File.write(text_path, "module Outer\n  def thing\n    42\n  end\nend\n")
    FileUtils.mkdir_p(File.dirname(binary_path))
    File.binwrite(binary_path, "\x00\x01\x02binary\x00")
  end

  after { FileUtils.rm_rf(tmp_dir) }

  it 'returns the relative path and contents for an existing text file' do
    result = tool.execute(path: 'lib/thing.rb')

    expect(result).to include('lib/thing.rb')
    expect(result).to include("module Outer\n  def thing\n    42\n  end\nend")
  end

  it 'reports when the path does not exist' do
    expect(tool.execute(path: 'lib/missing.rb')).to eq('Path `lib/missing.rb` does not exist.')
  end

  it 'reports does-not-exist when multiple intermediate directories are missing' do
    expect(tool.execute(path: 'a/b/c/missing.rb')).to eq('Path `a/b/c/missing.rb` does not exist.')
  end

  it 'reports when the path is a directory' do
    expect(tool.execute(path: 'lib')).to eq('Path `lib` is a directory.')
  end

  it 'rejects paths that escape the working directory via ..' do
    expect(tool.execute(path: '../sibling.txt')).to eq('Path `../sibling.txt` is outside the working directory.')
  end

  it 'rejects paths that escape via a symlinked intermediate directory' do
    outside = Dir.mktmpdir
    secret = File.join(outside, 'secret.txt')
    File.write(secret, 'leaked')
    link = File.join(tmp_dir, 'link')
    File.symlink(outside, link)

    begin
      expect(tool.execute(path: 'link/secret.txt')).to eq('Path `link/secret.txt` is outside the working directory.')
    ensure
      FileUtils.rm_f(link)
      FileUtils.rm_rf(outside)
    end
  end

  it 'rejects a symlink whose target points outside the working directory' do
    outside = Dir.mktmpdir
    secret = File.join(outside, 'secret.txt')
    File.write(secret, 'leaked')
    link = File.join(tmp_dir, 'secret.lnk')
    File.symlink(secret, link)

    begin
      expect(tool.execute(path: 'secret.lnk')).to eq('Path `secret.lnk` is outside the working directory.')
    ensure
      FileUtils.rm_f(link)
      FileUtils.rm_rf(outside)
    end
  end

  it 'rejects absolute paths outside the working directory' do
    expect(tool.execute(path: '/etc/passwd')).to eq('Path `/etc/passwd` is outside the working directory.')
  end

  it 'declines to read binary files' do
    result = tool.execute(path: 'assets/blob.bin')

    expect(result).to include('binary file')
    expect(result).to include('assets/blob.bin')
    expect(result).not_to include("\x00") # never dumps binary bytes
  end

  it 'stops a long file at MAX_LINES and says how much was left out' do
    File.write(File.join(tmp_dir, 'long.txt'), (1..2500).map { |n| "line #{n}\n" }.join)

    result = tool.execute(path: 'long.txt')

    expect(result).to include("line 2000\n")
    expect(result).not_to include("line 2001\n")
    expect(result).to end_with('Showing lines 1-2000 of 2500. Read on with offset: 2001, or use the search tool ' \
                               'with this path to find the lines you need.')
  end

  it 'reads the lines asked for with offset and limit', :aggregate_failures do
    File.write(File.join(tmp_dir, 'long.txt'), (1..2500).map { |n| "line #{n}\n" }.join)

    result = tool.execute(path: 'long.txt', offset: 2100, limit: 50)

    expect(result).to include("line 2100\nline 2101\n", "line 2149\n")
    expect(result).not_to include("line 2099\n", "line 2150\n")
    expect(result).to end_with('Showing lines 2100-2149 of 2500. Read on with offset: 2150, or use the search tool ' \
                               'with this path to find the lines you need.')
  end

  it 'caps a limit above MAX_LINES' do
    File.write(File.join(tmp_dir, 'long.txt'), (1..2500).map { |n| "line #{n}\n" }.join)

    expect(tool.execute(path: 'long.txt', limit: 5000)).to include('Showing lines 1-2000 of 2500.')
  end

  it 'says so when the offset is past the end' do
    File.write(File.join(tmp_dir, 'short.txt'), "one\ntwo\n")

    expect(tool.execute(path: 'short.txt', offset: 10)).to include('The file has 2 lines; offset 10 is past the end.')
  end

  it 'reads the last part of a file without a note to read on' do
    File.write(File.join(tmp_dir, 'short.txt'), "one\ntwo\nthree\n")

    expect(tool.execute(path: 'short.txt', offset: 2)).to end_with("```\nShowing lines 2-3 of 3.")
  end

  it 'stops a file of long lines at MAX_BYTES' do
    File.write(File.join(tmp_dir, 'wide.json'), Array.new(30) { |n| "#{n}#{'x' * 9_999}\n" }.join)

    result = tool.execute(path: 'wide.json')

    expect(result.bytesize).to be < 101_000
    expect(result).to include('Showing lines 1-9 of 30. Read on with offset: 10')
  end

  it 'shows the start of a single line longer than MAX_BYTES' do
    File.write(File.join(tmp_dir, 'minified.js'), 'a' * 300_000)

    result = tool.execute(path: 'minified.js')

    expect(result).to include('a' * 100_000)
    expect(result).not_to include('a' * 100_001)
    expect(result).to include('Line 1 is longer than 100000 bytes; showing its start.')
  end

  it 'degrades gracefully on unexpected errors' do
    allow(File).to receive(:exist?).and_raise(Errno::EACCES, 'boom')

    expected = 'File lookup unavailable for `lib/thing.rb`: Permission denied - boom'
    expect(tool.execute(path: 'lib/thing.rb')).to eq(expected)
  end
end
