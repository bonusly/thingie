module Notifications
  module Queries
    class ListNotifications
      DEFAULT_PER_PAGE = 30

      def self.call(user:, company:, unread_only: false, page: 1, per_page: DEFAULT_PER_PAGE)
        new(user: user, company: company, unread_only: unread_only, page: page, per_page: per_page).call
      end

      def initialize(user:, company:, unread_only:, page:, per_page:)
        @user = user
        @company = company
        @unread_only = unread_only
        @page = [page.to_i, 1].max
        @per_page = per_page.to_i.clamp(1, 100)
      end

      def call
        scope = Notification.for_company(company).for_recipient(user)
        scope = scope.unread if unread_only
        scope.recent.skip((page - 1) * per_page).limit(per_page)
      end

      private

      attr_reader :user, :company, :unread_only, :page, :per_page
    end
  end
end
