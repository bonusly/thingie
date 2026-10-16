module Points
  module Commands
    class ResetWeeklyBudgets
      def self.call(company:, now: Time.current)
        new(company: company, now: now).call
      end

      def initialize(company:, now:)
        @company = company
        @now = now
      end

      def call
        window = Points::Queries::WeeklyWindow.call(company: company, now: now)
        return Result.success(reset: 0, week_key: window.key) if already_reset?(window.key)

        count = 0
        company.memberships.active.each do |membership|
          next if membership.points_budget.zero?

          PointsLedgerEntry.create!(
            company: company, user: membership.user, amount: membership.points_budget,
            kind: "reset", week_key: window.key, note: "weekly budget"
          )
          count += 1
        end
        Result.success(reset: count, week_key: window.key)
      end

      private

      attr_reader :company, :now

      def already_reset?(week_key)
        PointsLedgerEntry.for_company(company).for_week(week_key).where(kind: "reset").exists?
      end
    end
  end
end
