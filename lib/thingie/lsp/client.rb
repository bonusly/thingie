# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'
require 'io/wait' # IO#wait_readable
require 'uri'
require_relative '../errors'

module Thingie
  module Lsp
    # Generic Language Server Protocol client: speaks JSON-RPC over the stdio of
    # a launched LSP process. Configured with a launch command, workspace root,
    # and optional server-specific initialization settings, so it works for any
    # LSP (ruby-lsp, gopls, etc.). The transport (spawn, framing, initialize handshake, request/
    # notify, server-request acks) is generic; symbol and contextual definition
    # requests supply source context for reviews.
    class Client # rubocop:disable Metrics/ClassLength
      INIT_TIMEOUT = 60 # ruby-lsp indexes the project at boot; allow time for it.
      REQUEST_TIMEOUT = 15
      # How long to wait for the server's first message before assuming it does
      # no background indexing (workspace/symbol is then usable immediately).
      READY_GRACE = 5
      LANGUAGE_IDS = {
        'rb' => 'ruby', 'rake' => 'ruby', 'erb' => 'erb',
        'ts' => 'typescript', 'tsx' => 'typescriptreact',
        'js' => 'javascript', 'jsx' => 'javascriptreact',
        'mjs' => 'javascript', 'cjs' => 'javascript'
      }.freeze

      # Builds a client; the server process itself isn't launched until the first {#lookup}.
      #
      # @param command [String, Array<String>] the LSP server launch command
      # @param root [String] the workspace root the server should index
      # @param initialization_options [Object, nil] optional server-specific LSP initialization options
      def initialize(command:, root:, initialization_options: nil)
        @command = Array(command)
        @root = File.expand_path(root)
        @initialization_options = initialization_options
        # ponytail: global lock per client serializes lookups and blocks the
        # Async reactor during a call; fine at review throughput (a handful of
        # concurrent fibers). Move to async IO if it ever bottlenecks.
        @mutex = Mutex.new
        @id = 0
        @started = false
        @indexed = false
      end

      # Look up symbols by name. Returns an array of LSP SymbolInformation
      # hashes ({ "name", "kind", "location" => { "uri", "range" } }).
      #
      # @param query [String] the symbol name to search for
      # @return [Array<Hash>] matching SymbolInformation hashes
      def lookup(query)
        @mutex.synchronize do
          start unless @started
          ensure_indexed
          Array(request('workspace/symbol', { query: query }, timeout: REQUEST_TIMEOUT))
        end
      end

      # Resolves a reference using zero-based UTF-16 LSP coordinates.
      #
      # @param path [String] absolute path to an existing source file
      # @param line [Integer] zero-based line
      # @param character [Integer] zero-based UTF-16 column
      # @return [Array<Hash>, nil] candidates, or nil when definitions are unsupported
      def definition(path:, line:, character:)
        @mutex.synchronize do
          start unless @started
          ensure_indexed
          provider = @capabilities['definitionProvider']
          return nil unless provider == true || provider.is_a?(Hash)

          document = { uri: file_uri(path) }
          opened = false
          begin
            notify('textDocument/didOpen', {
                     textDocument: document.merge(languageId: language_id(path), version: 1, text: File.read(path))
                   })
            opened = true
            result = request('textDocument/definition', {
                               textDocument: document, position: { line: line, character: character }
                             }, timeout: REQUEST_TIMEOUT)
            result.is_a?(Hash) ? [result] : (result || [])
          ensure
            notify('textDocument/didClose', { textDocument: document }) if opened
          end
        end
      rescue SystemCallError, IOError, JSON::ParserError => e
        raise LspError, "LSP definition failed: #{e.message}"
      end

      # Gracefully shuts down the LSP server: sends `shutdown`/`exit`, then closes
      # the process. Safe to call when the server was never started.
      #
      # @return [void]
      def shutdown
        @mutex.synchronize do
          return unless @started

          request('shutdown', nil, timeout: 5)
          notify('exit')
        rescue StandardError
          # Best effort — we're tearing down regardless.
        ensure
          close
        end
      end

      private

      def start
        @stdin, @stdout, @stderr, @wait = Open3.popen3(*@command, chdir: @root)
        response = request('initialize', initialize_params, timeout: REQUEST_TIMEOUT)
        @capabilities = response.fetch('capabilities', {})
        encoding = @capabilities['positionEncoding']
        raise LspError, "Unsupported LSP position encoding: #{encoding}" if encoding && encoding != 'utf-16'

        notify('initialized', {})
        # Mark started only after a successful handshake, so a failed init leaves
        # @started false (callers can retry) rather than trapped half-open.
        @started = true
      rescue Errno::ENOENT => e
        close
        raise LspError, "LSP command not found: #{@command.join(' ')} (#{e.message})"
      rescue StandardError
        close # don't leak the spawned process when init fails or times out
        raise
      end

      # workspace/symbol needs the project index; wait for it once, lazily, so
      # diagnostics-only servers (rubocop) never pay the indexing wait.
      def ensure_indexed
        return if @indexed

        wait_until_ready
        @indexed = true
      end

      # Servers that index in the background (e.g. ruby-lsp) report a work-done
      # progress sequence after `initialized`; workspace/symbol returns nothing
      # until it ends. Wait for that `end`, replying to any server requests along
      # the way. If no progress arrives within READY_GRACE, assume the server
      # needs no indexing and proceed.
      def wait_until_ready
        deadline = now + INIT_TIMEOUT
        return if @initial_progress == 'end'

        saw_progress = @initial_progress == 'begin'
        while (remaining = deadline - now).positive?
          # Until progress starts, only wait a short grace so a non-indexing
          # server isn't blocked for the full INIT_TIMEOUT.
          wait = saw_progress ? remaining : [remaining, READY_GRACE].min
          # wait_readable (not IO.select) so this yields to the Async scheduler.
          break unless @stdout.wait_readable(wait)

          message = read_message
          break if message.nil?

          answer_server_request(message)
          saw_progress ||= progress_kind(message) == 'begin'
          break if progress_kind(message) == 'end'
        end
      end

      def progress_kind(message)
        return nil unless message['method'] == '$/progress'

        message.dig('params', 'value', 'kind')
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def initialize_params
        params = {
          processId: Process.pid,
          rootUri: file_uri(@root),
          workspaceFolders: [{ uri: file_uri(@root), name: File.basename(@root) }],
          capabilities: {
            window: { workDoneProgress: true },
            workspace: { symbol: {} },
            general: { positionEncodings: ['utf-16'] },
            textDocument: { definition: { linkSupport: true } }
          }
        }
        params[:initializationOptions] = @initialization_options unless @initialization_options.nil?
        params
      end

      def file_uri(path)
        "file://#{URI::DEFAULT_PARSER.escape(path, %r{[^a-zA-Z0-9\-._~/]})}"
      end

      def language_id(path)
        extension = File.extname(path).downcase.delete_prefix('.')
        LANGUAGE_IDS.fetch(extension, extension)
      end

      def request(method, params, timeout:)
        id = (@id += 1)
        write({ jsonrpc: '2.0', id: id, method: method, params: params })
        Timeout.timeout(timeout, LspError, "LSP request timed out: #{method}") do
          read_until_response(id)
        end
      end

      def notify(method, params = nil)
        write({ jsonrpc: '2.0', method: method, params: params })
      end

      # Read messages until we get the response matching `id`, ignoring server
      # notifications and requests (e.g. progress, log messages) along the way.
      def read_until_response(id)
        loop do
          message = read_message
          raise LspError, "LSP connection closed waiting for #{id}" if message.nil?

          answer_server_request(message)
          kind = progress_kind(message)
          @initial_progress = kind if !@indexed && %w[begin end].include?(kind)
          next if message['method']
          next unless message['id'] == id

          raise LspError, "LSP error: #{message['error']}" if message['error']

          return message['result']
        end
      end

      # A message carrying both an id and a method is a server→client request
      # (e.g. window/workDoneProgress/create). Acknowledge it so the server
      # doesn't stall; we don't need its result.
      def answer_server_request(message)
        return unless message['id'] && message['method']

        write({ jsonrpc: '2.0', id: message['id'], result: nil })
      end

      def write(payload)
        body = JSON.generate(payload)
        @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        @stdin.flush
      end

      def read_message
        length = read_headers
        return nil if length.nil?

        body = @stdout.read(length)
        body && JSON.parse(body)
      end

      # Parse LSP headers, returning the Content-Length byte count (or nil at EOF).
      def read_headers
        length = nil
        while (line = @stdout.gets)
          line = line.strip
          break if line.empty? # blank line terminates the header block

          length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)\z/i
        end
        length
      end

      def close
        [@stdin, @stdout, @stderr].compact.each { |io| io.close unless io.closed? }
        reap
      rescue StandardError
        nil
      ensure
        @started = false
        @indexed = false
        @capabilities = {}
        @initial_progress = nil
      end

      # Closing the pipes makes a well-behaved server exit; escalate to TERM then
      # KILL so a hung server can never block the caller indefinitely.
      def reap
        return unless @wait&.alive?
        return if @wait.join(1)

        Process.kill('TERM', @wait.pid)
        return if @wait.join(2)

        Process.kill('KILL', @wait.pid)
      rescue StandardError
        nil
      end
    end
  end
end
