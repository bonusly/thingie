module Api
  module V1
    class SearchController < BaseController
      def index
        tasks = Tasks::Queries::ListTasks.call(
          company: current_company, user: current_user, filters: { q: params.require(:q), state: params[:state] }
        )
        render_collection(tasks, Tasks::Blueprints::TaskSummaryBlueprint)
      end

      def routes
        entries = Search::Queries::SearchRoutes.call(
          user: current_user, company: current_company, membership: current_membership, q: params[:q]
        )
        render json: Search::Blueprints::RouteBlueprint.render(entries)
      end
    end
  end
end
