module Search
  module Jobs
    class ReindexRoutesJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 1

      def perform
        routes = Search::Queries::DiscoverRoutes.call
        result = Search::Commands::UpsertRouteIndex.call(routes: routes)
        return if result.success?

        logger.error("route reindex failed: #{result.error}")
      end
    end
  end
end
