namespace :search do
  desc "Rebuild the route index from app/javascript/app-router.tsx"
  task reindex_routes: :environment do
    routes = Search::Queries::DiscoverRoutes.call
    result = Search::Commands::UpsertRouteIndex.call(routes: routes)
    abort(result.error.to_s) if result.failure?

    puts "indexed #{result.value[:upserted]} routes, dropped #{result.value[:dropped]}"
  end

  desc "List indexed routes and their permission gates"
  task routes: :environment do
    RouteIndexEntry.order(path: 1).each do |entry|
      puts format("%-40s %-28s %s", entry.path, entry.name, entry.permission || "-")
    end
  end
end
