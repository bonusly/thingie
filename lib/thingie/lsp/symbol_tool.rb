# frozen_string_literal: true

require 'ruby_llm'
require_relative '../llm_compat'
require 'uri'
require_relative '../errors'

module Thingie
  module Lsp
    # RubyLLM tool that lets the model fetch the definition of a class, module,
    # or method by name during a review, via a configured LSP client. Generic:
    # any LSP that implements workspace/symbol works here.
    class SymbolTool < RubyLLM::Tool
      MAX_RESULTS = 3
      # LSP SymbolKind values for local variables and instance/class fields. The
      # model asks about definitions (classes, methods, constants), so these rank
      # last — a fuzzy "User" query otherwise surfaces every `@user` assignment.
      VARIABLE_KINDS = [13, 8].freeze

      description <<~DESC
        Look up the definition of a class, module, or method by name to get more
        context about code referenced in the diff. Returns the source of matching
        definitions with their file paths. Query examples: "User", "User#save",
        "process_payment".
      DESC

      LlmCompat.parameter(self, :query, description: 'Name of the class, module, or method to look up', required: true)

      # Wraps an LSP client as a `ruby_llm` tool.
      #
      # @param client [Thingie::Lsp::Client] the LSP client to query
      # @param root [String] the workspace root, used to relativize file paths
      def initialize(client:, root:)
        super()
        @client = client
        @root = File.expand_path(root)
      end

      # Looks up the definition of a class, module, or method by name and returns
      # the source of the best matches.
      #
      # @param query [String] name of the class, module, or method to look up
      # @return [String] source snippets for matching definitions, or a not-found message
      def execute(query:)
        term = base_name(query)
        symbols = rank(Array(@client.lookup(term)), term).first(MAX_RESULTS)
        return "No definition found for `#{query}`." if symbols.empty?

        symbols.map { |symbol| render(symbol) }.compact.join("\n\n")
      rescue LspError => e
        # Degrade gracefully: a context lookup failure must not fail the review.
        "Symbol lookup unavailable for `#{query}`: #{e.message}"
      end

      private

      # workspace/symbol matches on a simple name, so reduce "Foo::Bar#baz",
      # "Thingie::LlmClient", or "@user" to the bare identifier.
      def base_name(name)
        name.to_s.split(/::|#|\./).last.to_s.gsub(/\A[@$]+/, '')
      end

      # Exact name matches first, then definitions over variables/fields, so the
      # most relevant results survive the MAX_RESULTS cap.
      def rank(symbols, term)
        symbols.sort_by do |symbol|
          exact = base_name(symbol['name']).casecmp?(term) ? 0 : 1
          [exact, VARIABLE_KINDS.include?(symbol['kind']) ? 1 : 0]
        end
      end

      def render(symbol)
        location = symbol['location'] || {}
        path = path_from_uri(location['uri'])
        return nil unless path && File.file?(path)

        range = location['range'] || {}
        source = slice(path, range)
        "#{relative(path)}:#{line_number(range)}\n```\n#{source}\n```"
      end

      # LSP ranges are 0-indexed [start.line, end.line] inclusive of the lines
      # the definition spans.
      def slice(path, range)
        first = range.dig('start', 'line') || 0
        last = range.dig('end', 'line') || first
        File.readlines(path)[first..last].to_a.join.rstrip
      end

      def line_number(range)
        (range.dig('start', 'line') || 0) + 1
      end

      # LSP file URIs are percent-encoded (RFC 3986), so a workspace path with a
      # space arrives as %20. Decode it back to a real filesystem path.
      def path_from_uri(uri)
        return nil unless uri

        URI::DEFAULT_PARSER.unescape(URI.parse(uri).path)
      rescue URI::InvalidURIError
        URI::DEFAULT_PARSER.unescape(uri.delete_prefix('file://'))
      end

      def relative(path)
        path.start_with?("#{@root}/") ? path.delete_prefix("#{@root}/") : path
      end
    end
  end
end
