module Api
  module V1
    class ExternalItemsController < BaseController
      def import
        item = ExternalItem.for_company(current_company).find(params[:id])
        authorize!(item.connector_account, :show?)
        list = Lists::Queries::FindList.call(company: current_company, id: params.require(:list_id))
        authorize!(Task.new(company: current_company, list: list), :create?)

        result = Connectors::Commands::ImportAsTask.call(item: item, actor: current_user, list: list)
        render_result(result, blueprint: Tasks::Blueprints::TaskBlueprint, status: :created)
      end
    end
  end
end
