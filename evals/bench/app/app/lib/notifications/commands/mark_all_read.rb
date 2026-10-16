module Notifications
  module Commands
    class MarkAllRead
      def self.call(user:, company:, before: Time.current)
        new(user: user, company: company, before: before).call
      end

      def initialize(user:, company:, before:)
        @user = user
        @company = company
        @before = before
      end

      def call
        scope = Notification.for_company(company).for_recipient(user).unread.where(:created_at.lte => before)
        count = scope.update_all(read_at: Time.current)
        Result.success(marked: count)
      end

      private

      attr_reader :user, :company, :before
    end
  end
end
