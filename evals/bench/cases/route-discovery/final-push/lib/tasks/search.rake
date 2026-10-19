namespace :search do
  desc "Rebuild the route index from app/javascript/app-router.tsx"
  task reindex_routes: :environment do
    routes = Search::Queries::DiscoverRoutes.call
    result = Search::Commands::UpsertRouteIndex.call(routes: routes)
    abort(result.error.to_s) if result.failure?

    summary = result.value
    puts "indexed #{summary[:upserted]} routes, #{summary[:unreadable]} unreadable, pruned #{summary[:pruned]}"
  end

  desc "List indexed routes with their permission gates and flags"
  task routes: :environment do
    RouteIndexEntry.order(path: 1).each do |entry|
      marker = entry.unreadable ? "?" : " "
      puts format("%s %-40s %-28s %-16s %s", marker, entry.path, entry.name, entry.permission || "-", entry.flag || "-")
    end
  end
end
