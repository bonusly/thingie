module Api
  module V1
    class MembershipsController < BaseController
      def index
        memberships = current_company.memberships.active.includes(:user)
        render json: memberships.map { |membership| serialize(membership) }
      end

      def update
        authorize!(membership, :update?)
        result = Admin::Commands::ChangeRole.call(membership: membership, actor: current_user, role: params.require(:role))
        return render_failure(result.error) if result.failure?

        render json: serialize(result.value)
      end

      def destroy
        authorize!(membership, :destroy?)
        membership.remove!
        head :no_content
      end

      private

      def membership
        @membership ||= current_company.memberships.active.find(params[:id])
      end

      def serialize(membership)
        {
          id: membership.id.to_s,
          user_id: membership.user_id.to_s,
          email: membership.user.email,
          name: membership.user.display_name,
          role: membership.role,
          points_budget: membership.points_budget,
          joined_at: membership.joined_at
        }
      end
    end
  end
end
