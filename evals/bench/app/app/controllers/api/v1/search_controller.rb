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
        entries = RouteIndexEntry.order(path: :asc)
        entries = entries.where(permission: params[:permission]) if params[:permission].present?
        render json: Search::Blueprints::RouteBlueprint.render(entries)
      end
    end
  end
end
