module Lists
  module Queries
    class ListLists
      def self.call(company:, user:, include_archived: false)
        new(company: company, user: user, include_archived: include_archived).call
      end

      def initialize(company:, user:, include_archived:)
        @company = company
        @user = user
        @include_archived = include_archived
      end

      def call
        scope = List.for_company(company).not_deleted.visible_to(user)
        scope = scope.where(state: "active") unless include_archived
        scope.ordered
      end

      private

      attr_reader :company, :user, :include_archived
    end
  end
end
