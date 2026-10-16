module Points
  module Queries
    class LedgerHistory
      DEFAULT_LIMIT = 50

      def self.call(user:, company:, weeks: 4, limit: DEFAULT_LIMIT)
        new(user: user, company: company, weeks: weeks, limit: limit).call
      end

      def initialize(user:, company:, weeks:, limit:)
        @user = user
        @company = company
        @weeks = weeks
        @limit = limit
      end

      def call
        PointsLedgerEntry.for_company(company).for_user(user).in(week_key: week_keys)
          .order(created_at: :desc).limit(limit)
      end

      private

      attr_reader :user, :company, :weeks, :limit

      def week_keys
        now = Time.current
        weeks.times.map do |offset|
          Points::Queries::WeeklyWindow.call(company: company, now: now - offset.weeks).key
        end
      end
    end
  end
end
