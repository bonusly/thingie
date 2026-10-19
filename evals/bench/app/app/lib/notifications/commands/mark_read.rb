module Notifications
  module Commands
    class MarkRead
      def self.call(notification:, user:)
        new(notification: notification, user: user).call
      end

      def initialize(notification:, user:)
        @notification = notification
        @user = user
      end

      def call
        return Result.failure(Notifications::NotRecipient.new) unless notification.recipient_id == user.id

        notification.mark_read!
        Result.success(notification)
      end

      private

      attr_reader :notification, :user
    end
  end
end
