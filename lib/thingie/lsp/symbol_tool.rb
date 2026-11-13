# frozen_string_literal: true

require 'ruby_llm'
require 'uri'
require_relative '../errors'

module Thingie
  module Lsp
    # Fetches source candidates through contextual definitions or name discovery.
    class SymbolTool < RubyLLM::Tool # rubocop:disable Metrics/ClassLength
      MAX_RESULTS = 3
      VARIABLE_KINDS = [13, 8].freeze

      description <<~DESC
        Look up source for a class, module, or method. Name search is discovery,
        not receiver resolution. For inheritance, private methods, super, or gem
        APIs, supply path, line, and column at the referenced token (or super),
        not its declaration. Contextual definitions use server receiver information,
        which can be ambiguous; neither misses nor ambiguous candidates prove absence.
        Query labels a contextual lookup; it does not choose a different occurrence.
      DESC

      parameter :query, description: 'Name of the class, module, or method to look up', required: true
      parameter :path, description: 'Workspace-relative source path; supply with line and column',
                       required: false
      parameter :line, description: '1-based line of the referenced token (or super), not its declaration',
                       type: 'integer', required: false
      parameter :column, description: '1-based UTF-16 column at that token; query only labels this occurrence',
                         type: 'integer', required: false

      # Wraps an LSP client as a `ruby_llm` tool.
      #
      # @param client [Thingie::Lsp::Client] the LSP client to query
      # @param root [String] the workspace root, used to relativize file paths
      def initialize(client:, root:)
        super()
        @client = client
        @root = File.realpath(root)
      end

      # Returns source candidates, optionally resolving a specific reference.
      #
      # @param query [String] name or label of the requested symbol
      # @param path [String, nil] workspace-relative call-site path
      # @param line [Integer, nil] one-based source line
      # @param column [Integer, nil] one-based UTF-16 source column
      # @return [String] source candidates or a lookup status
      def execute(query:, path: nil, line: nil, column: nil)
        sources = {}
        prefix = nil
        if [path, line, column].any? { |value| !value.nil? }
          resolved = context_path(path, line, column, sources)
          candidates = @client.definition(path: resolved, line: line - 1, character: column - 1)
          return contextual_result(candidates, query, "#{path}:#{line}:#{column}", sources) unless candidates.nil?

          prefix = 'Contextual definitions are not supported by this server; showing name-search candidates.'
        end
        candidates = name_candidates(query)
        return [prefix, "No definition found for `#{query}`."].compact.join("\n\n") if candidates.empty?

        if query.match?(/#|\./)
          prefix = [prefix, 'Name-search candidates; use path, line, and column to resolve the receiver.']
                   .compact.join("\n\n")
        end
        [prefix, render_candidates(candidates, query, sources)].compact.join("\n\n")
      rescue LspError, SystemCallError, IOError, ArgumentError => e
        ToolBudget::Failure.new("Symbol lookup unavailable for `#{query}`: #{e.message}")
      end

      private

      def context_path(path, line, column, sources)
        unless path.is_a?(String) && line.is_a?(Integer) && column.is_a?(Integer)
          raise ArgumentError, 'Supply path, line, and column together (integer, 1-based UTF-16 coordinates).'
        end
        if path.start_with?('/') || path.split('/').include?('..')
          raise ArgumentError, 'Use a workspace-relative path without traversal.'
        end

        resolved = File.realpath(File.expand_path(path, @root))
        unless resolved.start_with?("#{@root}/")
          raise ArgumentError, 'Context path must stay inside the workspace, including symlinks.'
        end

        lines = source_lines(resolved, sources)
        raise ArgumentError, 'Context path must be a readable UTF-8 text file.' unless lines
        unless line.positive? && line <= lines.size && column.positive? &&
               valid_position?(lines, line - 1, column - 1)
          raise ArgumentError, 'Coordinates must point inside a source line at a UTF-16 character boundary.'
        end
        if column - 1 == utf16_length(lines[line - 1].delete_suffix("\n").delete_suffix("\r"))
          raise ArgumentError, 'Column must point at the referenced token, not past the end of the line.'
        end

        resolved
      end

      def contextual_result(candidates, query, site, sources)
        if candidates.empty?
          return "No definition found for `#{query}` at #{site}. " \
                 'This is inconclusive, not proof that the symbol is undefined.'
        end

        "Definition candidates for #{query} at #{site}\n\n" \
          "#{render_candidates(candidates, query, sources, contextual: true)}"
      end

      def name_candidates(query)
        term = query.sub(/\A::/, '')
        term = base_name(query) unless term.include?('::') && !query.match?(/#|\./)
        symbols = @client.lookup(term)
        if term != base_name(query) && symbols.none? { |symbol| exact_name?(symbol, term) }
          symbols += @client.lookup(base_name(query))
        end
        symbols.sort_by do |symbol|
          tier = if exact_name?(symbol, query)
                   0
                 elsif base_name(symbol['name']).casecmp?(base_name(query))
                   1
                 else
                   2
                 end
          [tier, VARIABLE_KINDS.include?(symbol['kind']) ? 1 : 0]
        end
      end

      def exact_name?(symbol, query)
        name = symbol['name'].to_s.sub(/\A::/, '')
        qualified = [symbol['containerName'], name].compact.reject(&:empty?).join('::')
        [name, qualified].any? { |value| value.casecmp?(query.sub(/\A::/, '')) }
      end

      def base_name(name)
        name.to_s.split(/::|#|\./).last.to_s.gsub(/\A[@$]+/, '')
      end

      def render_candidates(candidates, query, sources, contextual: false)
        seen = {}
        snippets = candidates.filter_map do |candidate|
          location = candidate['location'] || candidate
          path = path_from_uri(location['targetUri'] || location['uri'])
          range = location['targetRange'] || location['range']
          next unless path && range.is_a?(Hash)

          key = [path, range]
          next if seen[key]

          seen[key] = true
          render(path, range, sources)
        end
        return "Definitions were found for `#{query}`, but no readable local source was available." if snippets.empty?

        notes = []
        notes << 'Multiple candidates; receiver resolution may be ambiguous.' if contextual && snippets.size > 1
        if snippets.size > MAX_RESULTS
          note = "#{snippets.size - MAX_RESULTS} candidates omitted."
          note += ' Supply contextual path, line, and column.' unless contextual
          notes << note
        end
        (snippets.first(MAX_RESULTS) + notes).join("\n\n")
      end

      def render(path, range, sources)
        lines = source_lines(path, sources)
        return nil unless lines

        first, last = range.values_at('start', 'end')
        return nil unless [first, last].all? do |position|
          position.is_a?(Hash) && valid_position?(lines, position['line'], position['character'])
        end
        return nil if ([last['line'], last['character']] <=> [first['line'], first['character']]) <= 0

        end_line = last['line'] - (last['character'].zero? && last['line'] > first['line'] ? 1 : 0)
        source = lines[first['line']..end_line].join.rstrip
        return nil if source.empty?

        "#{relative(path)}:#{first['line'] + 1}-#{end_line + 1}\n```\n#{source}\n```"
      end

      def source_lines(path, sources)
        return sources[path] if sources.key?(path)

        sources[path] = nil
        return nil unless File.file?(path) && File.readable?(path)

        text = File.read(path, encoding: 'UTF-8')
        return nil unless text.valid_encoding? && !text.include?("\0")

        sources[path] = text.lines
      rescue SystemCallError, IOError
        nil
      end

      def valid_position?(lines, line, character)
        return false unless line.is_a?(Integer) && character.is_a?(Integer) && line >= 0 && character >= 0
        return true if line == lines.size && character.zero? && lines.last&.end_with?("\n")
        return false unless line < lines.size

        text = lines[line].delete_suffix("\n").delete_suffix("\r")
        units = 0
        text.each_char do |char|
          return true if units == character

          units += utf16_length(char)
        end
        units == character
      end

      def utf16_length(text)
        text.encode('UTF-16LE').bytesize / 2
      end

      def path_from_uri(value)
        uri = URI.parse(value.to_s)
        return nil unless uri.scheme == 'file' && [nil, '', 'localhost'].include?(uri.host)
        return nil if uri.query || uri.fragment || !uri.path

        path = URI::DEFAULT_PARSER.unescape(uri.path).force_encoding('UTF-8')
        return nil unless path.valid_encoding? && path.start_with?('/') && !path.include?("\0")

        File.realpath(path)
      rescue URI::InvalidURIError, SystemCallError
        nil
      end

      def relative(path)
        path.start_with?("#{@root}/") ? path.delete_prefix("#{@root}/") : path
      end
    end
  end
end
