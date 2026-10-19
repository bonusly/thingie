module Search
  module Queries
    class SearchRoutes
      MEMBER = %w[tasks:read tasks:write lists:read lists:share drafts:read points:read connectors:read].freeze
      ADMIN = (MEMBER + %w[members:manage webhooks:manage]).freeze
      STAFF = (ADMIN + %w[admin:staff]).freeze

      def self.call(user:, company:, membership:, q: nil)
        new(user: user, company: company, membership: membership, q: q).call
      end

      def initialize(user:, company:, membership:, q:)
        @user = user
        @company = company
        @membership = membership
        @q = q.to_s.strip
      end

      def call
        scope = RouteIndexEntry.and(
          { "$or" => [{ permission: nil }, { permission: { "$in" => permissions } }] },
          { "$or" => [{ flag: nil }, { flag: { "$in" => company.enabled_flags } }] }
        )
        scope = scope.and("$or" => [{ name: matcher }, { path: matcher }]) if q.present?
        scope.order(path: :asc)
      end

      private

      attr_reader :user, :company, :membership, :q

      def permissions
        return STAFF if user.staff?

        membership.admin? ? ADMIN : MEMBER
      end

      def matcher
        /#{Regexp.escape(q)}/i
      end
    end
  end
end
