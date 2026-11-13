# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Lsp::SymbolTool do
  subject(:tool) { described_class.new(client: client, root: tmp_dir) }

  let(:tmp_dir) { Dir.mktmpdir }
  let(:file_path) { File.join(tmp_dir, 'lib', 'thing.rb') }
  let(:client) { instance_double(Thingie::Lsp::Client) }

  before do
    FileUtils.mkdir_p(File.dirname(file_path))
    File.write(file_path, "module Outer\n  def thing\n    42\n  end\nend\n")
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def symbol(start_line, end_line)
    {
      'name' => 'thing',
      'location' => {
        'uri' => "file://#{file_path}",
        'range' => { 'start' => { 'line' => start_line, 'character' => 0 },
                     'end' => { 'line' => end_line, 'character' => 5 } }
      }
    }
  end

  it 'returns the sliced definition source with a relative path', :aggregate_failures do
    allow(client).to receive(:lookup).with('thing').and_return([symbol(1, 3)])

    result = tool.execute(query: 'thing')

    expect(result).to include('lib/thing.rb:2') # 0-indexed line 1 => display line 2
    expect(result).to include("  def thing\n    42\n  end")
    expect(result).not_to include('module Outer') # outside the range
  end

  it 'reports when nothing is found' do
    allow(client).to receive(:lookup).and_return([])

    expect(tool.execute(query: 'missing')).to eq('No definition found for `missing`.')
  end

  it 'degrades gracefully when the client raises' do
    allow(client).to receive(:lookup).and_raise(Thingie::LspError, 'boom')

    expect(tool.execute(query: 'thing')).to eq('Symbol lookup unavailable for `thing`: boom')
  end

  it 'caps distinct readable results and explains omissions' do
    candidates = 4.times.map { |index| symbol(index, index) }
    candidates[2]['location']['range']['end']['character'] = 6
    allow(client).to receive(:lookup).and_return(candidates)
    result = tool.execute(query: 'thing')
    expect(result.scan('lib/thing.rb').size).to eq(described_class::MAX_RESULTS)
    expect(result).to include('1 candidates omitted', 'contextual path, line, and column')
  end

  it 'deduplicates locations before applying the cap' do
    allow(client).to receive(:lookup).and_return([symbol(1, 3)] * 4)
    expect(tool.execute(query: 'thing').scan('lib/thing.rb').size).to eq(1)
  end

  it 'continues past unusable candidates' do
    invalid = symbol(1, 3)
    invalid['location']['uri'] = 'https://example.com/source.rb'
    missing = symbol(1, 3)
    missing['location']['uri'] = "file://#{tmp_dir}/missing.rb"
    malformed = symbol(1, 3)
    malformed['location']['range'] = 'not a range'
    allow(client).to receive(:lookup).and_return([invalid, missing, malformed, symbol(99, 100), symbol(1, 3)])
    expect(tool.execute(query: 'thing')).to include('lib/thing.rb:2-4', '  end')
  end

  it 'explains when all matches lack readable local source' do
    allow(client).to receive(:lookup).and_return([symbol(99, 100)])
    expect(tool.execute(query: 'thing')).to eq(
      'Definitions were found for `thing`, but no readable local source was available.'
    )
  end

  it 'excludes the final line when the exclusive end is column zero' do
    candidate = symbol(1, 4)
    candidate['location']['range']['end']['character'] = 0
    allow(client).to receive(:lookup).and_return([candidate])
    expect(tool.execute(query: 'thing')).to include("lib/thing.rb:2-4\n", "  end\n```")
  end

  it 'queries the full constant path and prefers its namespace' do
    other = symbol(0, 4).merge('name' => 'Thing', 'containerName' => 'Other')
    other['location']['range']['end']['character'] = 3
    wanted = symbol(1, 3).merge('name' => 'Thing', 'containerName' => 'Outer')
    allow(client).to receive(:lookup).with('Outer::Thing').and_return([other, wanted])
    expect(tool.execute(query: '::Outer::Thing')).to start_with('lib/thing.rb:2-4')
  end

  it 'falls back to the base constant name only after a full-name miss' do
    allow(client).to receive(:lookup).with('Outer::Thing').and_return([])
    allow(client).to receive(:lookup).with('Thing').and_return([symbol(1, 3)])
    expect(tool.execute(query: 'Outer::Thing')).to include('def thing')
    expect(client).to have_received(:lookup).with('Outer::Thing').ordered
    expect(client).to have_received(:lookup).with('Thing').ordered
  end

  it 'labels qualified method searches as discovery' do
    allow(client).to receive(:lookup).with('thing').and_return([symbol(1, 3)])
    expect(tool.execute(query: 'Outer#thing')).to include('Name-search candidates; use path, line, and column')
  end

  context 'with call-site context' do
    let(:context) { { query: 'thing', path: 'lib/thing.rb', line: 2, column: 7 } }

    it 'renders a parent LocationLink using the full target range without workspace search' do
      location = symbol(1, 3)['location']
      link = { 'targetUri' => location['uri'], 'targetRange' => location['range'],
               'targetSelectionRange' => symbol(1, 1)['location']['range'] }
      allow(client).to receive(:definition).and_return([link])
      allow(client).to receive(:lookup)
      result = tool.execute(**context)
      expect(result).to include('Definition candidates for thing at lib/thing.rb:2:7', "  end\n```")
      expect(client).to have_received(:definition).with(path: File.realpath(file_path), line: 1, character: 6)
      expect(client).not_to have_received(:lookup)
    end

    it 'reads dependency targets outside the workspace' do
      Dir.mktmpdir do |dependency|
        target = File.join(dependency, 'parent.rb')
        File.write(target, "def work\n  :base\nend\n")
        location = symbol(0, 2)['location']
        location['uri'] = "file://#{target}"
        location['range']['end']['character'] = 3
        allow(client).to receive(:definition).and_return([location])
        expect(tool.execute(**context)).to include(target, ':base', "end\n```")
      end
    end

    it 'keeps supported misses inconclusive without name fallback' do
      allow(client).to receive(:definition).and_return([])
      allow(client).to receive(:lookup)
      result = tool.execute(**context)
      expect(result).to include('No definition found for `thing` at lib/thing.rb:2:7', 'inconclusive, not proof')
      expect(client).not_to have_received(:lookup)
    end

    it 'visibly falls back only when definitions are unsupported' do
      allow(client).to receive_messages(definition: nil, lookup: [symbol(1, 3)])
      expect(tool.execute(**context)).to include('Contextual definitions are not supported', 'def thing')
    end

    it 'preserves candidate order and warns about ambiguity' do
      second = symbol(0, 4)['location']
      second['range']['end']['character'] = 3
      allow(client).to receive(:definition).and_return([symbol(1, 3)['location'], second])
      result = tool.execute(**context)
      expect(result.index('lib/thing.rb:2-4')).to be < result.index('lib/thing.rb:1-5')
      expect(result).to include('Multiple candidates; receiver resolution may be ambiguous.')
    end

    it 'reports contextual omissions without asking for coordinates already supplied' do
      candidates = 4.times.map { |index| symbol(index, index)['location'] }
      candidates[2]['range']['end']['character'] = 6
      allow(client).to receive(:definition).and_return(candidates)
      result = tool.execute(**context)
      expect(result).to include('1 candidates omitted.')
      expect(result).not_to include('Supply contextual', 'supply contextual')
    end

    it 'validates UTF-16 coordinates rather than bytes or codepoints' do
      File.write(file_path, "é😀; thing\n")
      allow(client).to receive(:definition).and_return([])
      expect(tool.execute(**context, line: 1, column: 6)).to include('inconclusive')
      expect(tool.execute(**context, line: 1, column: 3)).to be_a(Thingie::ToolBudget::Failure)
      expect(client).to have_received(:definition).with(path: File.realpath(file_path), line: 0, character: 5).once
    end

    it 'rejects partial, traversing, absolute, and out-of-bounds context before calling the server' do
      allow(client).to receive_messages(definition: [], lookup: [])
      [{ column: nil }, { path: '../thing.rb' }, { path: file_path },
       { line: 0 }, { line: 6 }, { column: 100 }, { line: 2, column: 12 }].each do |invalid|
        expect(tool.execute(**context, **invalid)).to be_a(Thingie::ToolBudget::Failure)
      end
      expect(client).not_to have_received(:definition)
      expect(client).not_to have_received(:lookup)
    end

    it 'rejects symlink escapes and binary context before any LSP call' do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, 'escape.rb'), 'thing')
        File.symlink(outside, File.join(tmp_dir, 'escape'))
        File.write(file_path, "\0thing")
        allow(client).to receive_messages(definition: [], lookup: [])
        expect(tool.execute(**context, path: 'escape/escape.rb')).to be_a(Thingie::ToolBudget::Failure)
        expect(tool.execute(**context)).to be_a(Thingie::ToolBudget::Failure)
        expect(client).not_to have_received(:definition)
        expect(client).not_to have_received(:lookup)
      end
    end
  end
end
