module Points
  module Commands
    class Award
      def self.call(company:, user:, task:, amount:, now: Time.current)
        new(company: company, user: user, task: task, amount: amount, now: now).call
      end

      def initialize(company:, user:, task:, amount:, now:)
        @company = company
        @user = user
        @task = task
        @amount = amount.to_i
        @now = now
      end

      def call
        return Result.failure("amount must be positive") unless amount.positive?

        balance = Points::Queries::GivingBalance.call(user: user, company: company, now: now)
        unless balance.covers?(amount)
          return Result.failure(Points::InsufficientBalance.new(requested: amount, remaining: balance.remaining))
        end

        entry = PointsLedgerEntry.create!(
          company: company, user: user, task: task, amount: amount, kind: "award", week_key: balance.week_key
        )
        TaskEvent.track!(task: task, actor: user, kind: "points_awarded", data: { amount: amount })
        Result.success(entry)
      rescue Points::NotAMember => e
        Result.failure(e)
      end

      private

      attr_reader :company, :user, :task, :amount, :now
    end
  end
end
