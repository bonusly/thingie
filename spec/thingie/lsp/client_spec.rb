# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Lsp::Client do
  subject(:client) { described_class.new(command: ['ruby', fake_server], root: tmp_dir) }

  let(:tmp_dir) { Dir.mktmpdir('lsp #é% ') }
  let(:capabilities) { { definitionProvider: true } }
  let(:source_path) { File.join(tmp_dir, 'source #é%.rb') }
  let(:messages) { File.readlines(File.join(tmp_dir, 'messages.jsonl')).map { |line| JSON.parse(line) } }
  # A minimal stand-in LSP server: speaks Content-Length framed JSON-RPC,
  # responds to initialize and workspace/symbol. Exercises our framing and id
  # correlation without depending on a real language server.
  let(:fake_server) do
    path = File.join(tmp_dir, 'fake_lsp.rb')
    # Single-quoted heredoc: the body is written verbatim, so #{...} and regex
    # escapes belong to the generated script, not this spec.
    File.write(path, <<~'RUBY')
      require 'json'
      $stdin.binmode
      $stdout.binmode
      def read_message
        len = nil
        while (line = $stdin.gets)
          line = line.strip
          break if line.empty?
          len = $1.to_i if line =~ /Content-Length:\s*(\d+)/i
        end
        len && JSON.parse($stdin.read(len))
      end
      def send_msg(obj)
        body = JSON.generate(obj)
        $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        $stdout.flush
      end
      loop do
        msg = read_message or break
        File.open('messages.jsonl', 'a') { |file| file.puts(JSON.generate(msg)) }
        case msg['method']
        when 'initialize'
          send_msg(jsonrpc: '2.0', id: msg['id'], method: 'window/workDoneProgress/create', params: { token: 'index' })
          send_msg(jsonrpc: '2.0', method: '$/progress', params: { value: { kind: 'begin' } })
          send_msg(jsonrpc: '2.0', id: msg['id'], result: { capabilities: JSON.parse(File.read('capabilities.json')) })
        when 'initialized' # signal "indexing done" so the readiness wait returns at once
          send_msg(jsonrpc: '2.0', method: '$/progress', params: { value: { kind: 'end' } })
        when 'workspace/symbol'
          send_msg(jsonrpc: '2.0', id: msg['id'], result: [
            { 'name' => msg.dig('params', 'query'),
              'location' => { 'uri' => 'file:///x.rb', 'range' => { 'start' => { 'line' => 0 } } } }
          ])
        when 'textDocument/definition'
          if msg.dig('params', 'position', 'line') == 99
            send_msg(jsonrpc: '2.0', id: msg['id'], error: { code: -32603, message: 'definition failed' })
          else
            location = { uri: msg.dig('params', 'textDocument', 'uri'),
                         range: { start: { line: 0, character: 0 }, end: { line: 1, character: 3 } } }
            result = msg.dig('params', 'position', 'character') == 1 ?
              [{ targetUri: location[:uri], targetRange: location[:range] }] : location
            send_msg(jsonrpc: '2.0', id: msg['id'], result: result)
          end
        when 'shutdown' then send_msg(jsonrpc: '2.0', id: msg['id'], result: nil)
        when 'exit' then break
        end
      end
    RUBY
    path
  end

  before do
    File.write(File.join(tmp_dir, 'capabilities.json'), JSON.generate(capabilities))
    File.write(source_path, "class Source\nend\n")
  end

  # Teardown (not an it-level ensure) so a shutdown error can't mask an
  # assertion failure; shutdown is a no-op when the client never started.
  after do
    client.shutdown
    FileUtils.rm_rf(tmp_dir)
  end

  it 'initializes and returns workspace/symbol results' do
    results = client.lookup('Widget')
    expect(results).to eq([
                            { 'name' => 'Widget',
                              'location' => { 'uri' => 'file:///x.rb', 'range' => { 'start' => { 'line' => 0 } } } }
                          ])
  end

  it 'omits server-specific initialization options when unconfigured' do
    client.lookup('Widget')
    client.shutdown
    expect(messages.first.fetch('params')).not_to have_key('initializationOptions')
  end

  it 'preserves nested server-specific options and false values in the initialize request' do
    options = {
      'tsserver' => { 'useSyntaxServer' => 'never' },
      'preferences' => { 'includeCompletionsForModuleExports' => false }
    }
    configured = described_class.new(command: ['ruby', fake_server], root: tmp_dir, initialization_options: options)
    begin
      configured.lookup('Widget')
    ensure
      configured.shutdown
    end
    expect(messages.first.dig('params', 'initializationOptions')).to eq(options)
  end

  it 'opens source documents with canonical language IDs and preserves unknown extensions' do
    expected = {
      'rb' => 'ruby', 'rake' => 'ruby', 'erb' => 'erb',
      'ts' => 'typescript', 'tsx' => 'typescriptreact',
      'js' => 'javascript', 'jsx' => 'javascriptreact',
      'mjs' => 'javascript', 'cjs' => 'javascript', 'CUSTOM' => 'custom'
    }
    expected.each_key do |extension|
      path = File.join(tmp_dir, "source.#{extension}")
      File.write(path, "source\n")
      client.definition(path: path, line: 0, character: 0)
    end
    client.shutdown
    opened = messages.select { |message| message['method'] == 'textDocument/didOpen' }
    expect(opened.map { |message| message.dig('params', 'textDocument', 'languageId') }).to eq(expected.values)
  end

  it 'raises LspError when the command does not exist' do
    bad = described_class.new(command: ['definitely-not-a-real-lsp-binary'], root: tmp_dir)
    expect { bad.lookup('x') }.to raise_error(Thingie::LspError, /not found/)
  end

  it 'serializes concurrent document lifetimes and initializes once' do
    results = [0, 1].map do |character|
      Thread.new { client.definition(path: source_path, line: 0, character: character) }
    end.map(&:value)
    client.shutdown

    expect(results.map(&:size)).to eq([1, 1])
    expect(results[0][0]).to have_key('uri')
    expect(results[1][0]).to have_key('targetUri')
    methods = messages.map { |message| message['method'] }
    expect(methods.count('initialize')).to eq(1)
    expect(methods.count('initialized')).to eq(1)
    lifecycle = %w[textDocument/didOpen textDocument/definition textDocument/didClose]
    expect(methods.grep(/textDocument/)).to eq(lifecycle * 2)
    opened = messages.find { |message| message['method'] == 'textDocument/didOpen' }.dig('params', 'textDocument')
    expect(URI::DEFAULT_PARSER.unescape(URI.parse(opened['uri']).path)).to eq(source_path)
    expect(opened).to include('text' => File.read(source_path), 'languageId' => 'ruby', 'version' => 1)
    initialization = messages.first['params']
    expect(URI::DEFAULT_PARSER.unescape(URI.parse(initialization['rootUri']).path)).to eq(tmp_dir)
    expect(initialization.dig('capabilities', 'general', 'positionEncodings')).to eq(['utf-16'])
  end

  it 'closes the document after a failed request' do
    expect { client.definition(path: source_path, line: 99, character: 0) }.to raise_error(Thingie::LspError)
    client.shutdown
    lifecycle = %w[textDocument/didOpen textDocument/definition textDocument/didClose]
    expect(messages.map { |message| message['method'] }.grep(/textDocument/)).to eq(lifecycle)
  end

  context 'with definition options' do
    let(:capabilities) { { definitionProvider: {} } }

    it 'treats the options object as supported' do
      result = client.definition(path: source_path, line: 0, character: 0)
      expect(result.first.fetch('uri')).to include('source%20%23')
    end
  end

  context 'without definition support' do
    let(:capabilities) { { definitionProvider: false } }

    it 'returns nil without opening or requesting definitions' do
      expect(client.definition(path: source_path, line: 0, character: 0)).to be_nil
      client.shutdown
      expect(messages.map { |message| message['method'] }.grep(/textDocument/)).to be_empty
    end
  end

  context 'with an incompatible encoding' do
    let(:capabilities) { { positionEncoding: 'utf-8', definitionProvider: {} } }

    it 'rejects the negotiated encoding' do
      expect { client.definition(path: source_path, line: 0, character: 0) }
        .to raise_error(Thingie::LspError, /position encoding/)
    end
  end
end
