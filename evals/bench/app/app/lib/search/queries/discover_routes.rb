module Search
  module Queries
    class DiscoverRoutes
      Route = Struct.new(:path, :name, :component, :permission, keyword_init: true) do
        def gated?
          permission.present?
        end
      end

      DEFAULT_ROUTER = "app/javascript/app-router.tsx".freeze

      ENTRY = /\{\s*path:\s*"(?<path>[^"]*)"\s*,\s*name:\s*"(?<name>[^"]*)"\s*,\s*component:\s*lazy\(\(\)\s*=>\s*import\("(?<component>[^"]*)"\)\)(?:\s*,\s*permission:\s*"(?<permission>[^"]*)")?\s*,?\s*\}/m

      def self.call(router_path: Rails.root.join(DEFAULT_ROUTER))
        new(router_path: router_path).call
      end

      def initialize(router_path:)
        @router_path = router_path
      end

      def call
        raise Search::RouterMissing, router_path unless File.exist?(router_path)

        source = File.read(router_path)
        routes = source.to_enum(:scan, ENTRY).map { build_route(Regexp.last_match) }
        raise Search::RouterEmpty, router_path if routes.empty?

        routes
      end

      private

      attr_reader :router_path

      def build_route(match)
        Route.new(
          path: match[:path],
          name: match[:name],
          component: File.basename(match[:component]),
          permission: match[:permission].presence
        )
      end
    end
  end
end
