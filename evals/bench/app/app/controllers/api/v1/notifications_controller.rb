module Api
  module V1
    class NotificationsController < BaseController
      BLUEPRINT = Notifications::Blueprints::NotificationBlueprint

      def index
        notifications = Notifications::Queries::ListNotifications.call(
          user: current_user, company: current_company, unread_only: params[:unread] == "true", page: page, per_page: per_page
        )
        response.set_header("X-Unread-Count", unread_count.to_s)
        render json: BLUEPRINT.render(notifications)
      end

      def show
        render json: BLUEPRINT.render(notification)
      end

      def mark_read
        render_result(Notifications::Commands::MarkRead.call(notification: notification, user: current_user), blueprint: BLUEPRINT)
      end

      def mark_all_read
        result = Notifications::Commands::MarkAllRead.call(user: current_user, company: current_company)
        render json: result.value
      end

      private

      def unread_count
        Notification.for_company(current_company).for_recipient(current_user).unread.count
      end

      def notification
        @notification ||= Notification.for_company(current_company).for_recipient(current_user).where(id: params[:id]).first ||
                          raise(Notifications::NotFound, params[:id])
      end
    end
  end
end
