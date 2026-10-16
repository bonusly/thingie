module Points
  module Queries
    class GivingBalance
      Balance = Struct.new(:budget, :spent, :reserved, :remaining, :week_key, keyword_init: true) do
        def covers?(amount)
          amount <= remaining
        end
      end

      def self.call(user:, company:, now: Time.current)
        new(user: user, company: company, now: now).call
      end

      def initialize(user:, company:, now:)
        @user = user
        @company = company
        @now = now
      end

      def call
        raise Points::NotAMember.new(user, company) if membership.nil?

        budget = membership.points_budget
        spent = sent_points
        reserved = reserved_points
        Balance.new(
          budget: budget,
          spent: spent,
          reserved: reserved,
          remaining: [budget - spent - reserved, 0].max,
          week_key: window.key
        )
      end

      private

      attr_reader :user, :company, :now

      def membership
        @membership ||= user.membership_for(company)
      end

      def window
        @window ||= Points::Queries::WeeklyWindow.call(company: company, now: now)
      end

      def sent_points
        entries = PointsLedgerEntry.for_company(company).for_user(user).for_week(window.key)
        entries.awards.sum(:amount) - entries.refunds.sum(:amount)
      end

      def reserved_points
        DraftTask.for_company(company).ready.by_author(user).sum(:points)
      end
    end
  end
end
