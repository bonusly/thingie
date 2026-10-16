module Search
  module Commands
    class UpsertRouteIndex
      def self.call(routes:, now: Time.current)
        new(routes: routes, now: now).call
      end

      def initialize(routes:, now:)
        @routes = routes
        @now = now
      end

      def call
        readable, dropped = routes.partition { |route| readable?(route) }
        upserted = one_per_route_path(readable).each { |route| upsert(route) }
        prune(upserted.map(&:path))
        Result.success(upserted: upserted.size, dropped: dropped.size)
      end

      private

      attr_reader :routes, :now

      def readable?(route)
        route.path.to_s.start_with?("/") && route.name.present? && route.component.present?
      end

      def one_per_route_path(list)
        list.each_with_object({}) { |route, by_path| by_path[route.path] ||= route }.values
      end

      def upsert(route)
        entry = RouteIndexEntry.find_or_initialize_by(path: route.path)
        entry.update!(name: route.name, component: route.component, permission: route.permission, indexed_at: now)
      end

      def prune(paths)
        RouteIndexEntry.nin(path: paths).delete_all
      end
    end
  end
end
