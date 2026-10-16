module Notifications
  module Jobs
    class DeliverNotificationJob
      include Sidekiq::Job

      sidekiq_options queue: :notifications, retry: 5

      def perform(notification_id)
        notification = Notification.where(id: notification_id).first
        return if notification.nil? || notification.read?

        recipient = notification.recipient
        return unless recipient.member_of?(notification.company)

        NotificationMailer.single(notification).deliver_now
      end
    end
  end
end
