module Admin
  class RouteIndexesController < BaseController
    def show
      entries = RouteIndexEntry.order(path: :asc)
      render json: {
        count: entries.count,
        last_indexed_at: entries.max(:indexed_at),
        routes: Search::Blueprints::RouteBlueprint.render_as_hash(entries)
      }
    end

    def create
      admin_authorize!(RouteIndexEntry, :reindex?)
      routes = Search::Queries::DiscoverRoutes.call
      result = Search::Commands::UpsertRouteIndex.call(routes: routes)
      render json: result.value, status: :created
    end
  end
end
