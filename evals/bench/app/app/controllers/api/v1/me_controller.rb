module Api
  module V1
    class MeController < BaseController
      PERMITTED = %i[name time_zone locale].freeze

      def show
        render json: profile
      end

      def update
        current_user.update!(params.require(:user).permit(*PERMITTED))
        render json: profile
      end

      private

      def profile
        {
          id: current_user.id.to_s,
          email: current_user.email,
          name: current_user.display_name,
          time_zone: current_user.time_zone,
          locale: current_user.locale,
          staff: current_user.staff,
          company: { id: current_company.id.to_s, name: current_company.name, slug: current_company.slug },
          role: current_membership.role,
          unread_notifications: Notification.for_company(current_company).for_recipient(current_user).unread.count
        }
      end
    end
  end
end
