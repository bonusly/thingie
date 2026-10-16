module Api
  module V1
    module ConnectorAccounts
      class ExternalItemsController < BaseController
        def index
          authorize!(account, :show?)
          scope = account.external_items
          scope = scope.where(kind: params[:kind]) if params[:kind].present?
          scope = scope.unimported if params[:unimported] == "true"
          render_collection(scope.newest_first, Connectors::Blueprints::ExternalItemBlueprint)
        end

        private

        def account
          @account ||= ConnectorAccount.for_company(current_company).find(params[:connector_account_id])
        end
      end
    end
  end
end
