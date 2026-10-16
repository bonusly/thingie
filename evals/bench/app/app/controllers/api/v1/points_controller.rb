module Api
  module V1
    class PointsController < BaseController
      def show
        balance = Points::Queries::GivingBalance.call(user: current_user, company: current_company)
        render json: Points::Blueprints::BalanceBlueprint.render(balance)
      end

      def ledger
        entries = Points::Queries::LedgerHistory.call(
          user: current_user, company: current_company, weeks: params.fetch(:weeks, 4).to_i.clamp(1, 26)
        )
        render json: Points::Blueprints::LedgerEntryBlueprint.render(entries)
      end
    end
  end
end
