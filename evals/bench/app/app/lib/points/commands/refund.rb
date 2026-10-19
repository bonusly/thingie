module Points
  module Commands
    class Refund
      def self.call(entry:, note: nil)
        new(entry: entry, note: note).call
      end

      def initialize(entry:, note:)
        @entry = entry
        @note = note
      end

      def call
        return Result.failure("only awards can be refunded") unless entry.award?
        return Result.failure("already refunded") if refunded?

        refund = PointsLedgerEntry.create!(
          company: entry.company, user: entry.user, task: entry.task,
          amount: entry.amount, kind: "refund", week_key: entry.week_key, note: note
        )
        Result.success(refund)
      end

      private

      attr_reader :entry, :note

      def refunded?
        PointsLedgerEntry.for_company(entry.company).refunds.where(task_id: entry.task_id, user_id: entry.user_id).exists?
      end
    end
  end
end
