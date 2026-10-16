module Search
  module Services
    class RouteParser
      ROUTES_ARRAY = /export const routes(?::\s*RouteDefinition\[\])?\s*=\s*\[/
      OPENERS = { "{" => "}", "[" => "]", "(" => ")" }.freeze
      CLOSERS = OPENERS.values.freeze
      KEY = /\A\s*(?<key>\w+)\s*:/
      STRING = /\A\s*"(?<value>[^"]*)"\s*\z/
      LAZY = /\A(?:requireAdmin\()?\s*lazy\(\(\)\s*=>\s*import\("(?<module>[^"]*)"\)\)\)?\s*\z/
      ADMIN_PERMISSION = "admin:staff".freeze

      def initialize(source:, resolver:, path: nil)
        @source = source
        @masked = SourceMask.call(source)
        @resolver = resolver
        @path = path
      end

      def call
        match = masked.match(ROUTES_ARRAY)
        return [] unless match

        open = match.end(0) - 1
        entries(open + 1, closing_index(open), inherited: {})
      end

      private

      attr_reader :source, :masked, :resolver, :path

      def entries(from, to, inherited:)
        routes = []
        index = from
        while index < to
          if masked[index] == "{"
            close = closing_index(index)
            routes.concat(entry(index, close, inherited))
            index = close + 1
          else
            index += 1
          end
        end
        routes
      end

      def entry(open, close, inherited)
        fields = {}
        segments(open + 1, close).each do |from, to|
          key = masked[from...to][KEY, :key]
          fields[key] = [from + masked[from...to].index(":") + 1, to] if key
        end
        return [] unless fields["path"]

        gates = {
          permission: inherited[:permission] || gate(fields["permission"]) || wrapped_permission(fields["component"]),
          flag: inherited[:flag] || gate(fields["flag"])
        }
        route = Search::Queries::DiscoverRoutes::Route.new(
          path: string_at(fields["path"]), name: string_at(fields["name"]), component: component_at(fields["component"]), **gates
        )
        children = fields["children"] ? entries(*fields["children"], inherited: gates) : []
        [route] + children
      end

      def segments(from, to)
        depth = 0
        start = from
        parts = []
        (from...to).each do |index|
          char = masked[index]
          depth += 1 if OPENERS.key?(char)
          depth -= 1 if CLOSERS.include?(char)
          next unless char == "," && depth.zero?

          parts << [start, index]
          start = index + 1
        end
        parts << [start, to]
        parts.reject { |a, b| masked[a...b].strip.empty? }
      end

      def closing_index(open)
        depth = 0
        (open...masked.size).each do |index|
          depth += 1 if OPENERS.key?(masked[index])
          depth -= 1 if CLOSERS.include?(masked[index])
          return index if depth.zero?
        end
        raise Search::ParseError.new(path, open)
      end

      def gate(range)
        return nil unless range

        text = source[range[0]...range[1]].strip
        text[STRING, :value] || resolver.call(text)
      end

      def wrapped_permission(range)
        range && source[range[0]...range[1]].strip.start_with?("requireAdmin(") ? ADMIN_PERMISSION : nil
      end

      def string_at(range)
        range && source[range[0]...range[1]][STRING, :value]
      end

      def component_at(range)
        return nil unless range

        match = LAZY.match(source[range[0]...range[1]].strip)
        match && File.basename(match[:module])
      end
    end
  end
end
