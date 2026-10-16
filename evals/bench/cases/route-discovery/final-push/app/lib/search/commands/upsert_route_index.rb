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
        readable, unreadable = routes.partition(&:readable?)
        kept = one_per_route_path(readable).each { |route| upsert(route) }
        kept_paths = kept.map(&:path)
        marked = (unreadable.map(&:path).compact.uniq - kept_paths).select { |path| mark_unreadable(path) }
        pruned = prune(kept_paths + marked)
        Result.success(upserted: kept.size, unreadable: marked.size, pruned: pruned)
      end

      private

      attr_reader :routes, :now

      def one_per_route_path(list)
        list.each_with_object({}) { |route, by_path| by_path[route.path] = route }.values
      end

      def upsert(route)
        entry = RouteIndexEntry.find_or_initialize_by(path: route.path)
        entry.update!(
          name: route.name, component: route.component, permission: route.permission, flag: route.flag,
          unreadable: false, indexed_at: now
        )
      end

      def mark_unreadable(path)
        RouteIndexEntry.where(path: path).update_all(unreadable: true, indexed_at: now).matched_count.positive?
      end

      def prune(paths)
        RouteIndexEntry.nin(path: paths).delete_all
      end
    end
  end
end
