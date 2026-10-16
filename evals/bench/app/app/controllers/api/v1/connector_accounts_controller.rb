module Api
  module V1
    class ConnectorAccountsController < BaseController
      BLUEPRINT = Connectors::Blueprints::ConnectorAccountBlueprint

      def index
        scope = ConnectorAccount.for_company(current_company).where(:state.ne => "disconnected")
        scope = scope.where(user_id: current_user.id) unless current_membership.admin?
        render json: BLUEPRINT.render(scope.order(created_at: :desc))
      end

      def create
        result = Connectors::Commands::ConnectAccount.call(
          company: current_company, user: current_user, **connect_params
        )
        render_result(result, blueprint: BLUEPRINT, status: :created)
      end

      def destroy
        authorize!(account, :destroy?)
        head_result(Connectors::Commands::DisconnectAccount.call(account: account, actor: current_user))
      end

      def sync
        authorize!(account, :sync?)
        Connectors::Jobs::SyncAccountJob.perform_async(account.id.to_s)
        head :accepted
      end

      def pause
        authorize!(account, :pause?)
        account.pause!
        render json: BLUEPRINT.render(account)
      end

      def resume
        authorize!(account, :resume?)
        account.resume!
        render json: BLUEPRINT.render(account)
      end

      private

      def account
        @account ||= ConnectorAccount.for_company(current_company).find(params[:id])
      end

      def connect_params
        params.require(:connector_account)
              .permit(:provider, :external_account_id, :external_account_name, :access_token)
              .to_h.symbolize_keys
      end
    end
  end
end
