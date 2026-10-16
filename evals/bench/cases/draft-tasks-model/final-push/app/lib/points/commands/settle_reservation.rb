module Points
  module Commands
    class SettleReservation
      def self.call(draft:, task:, amount:, now: Time.current)
        new(draft: draft, task: task, amount: amount, now: now).call
      end

      def initialize(draft:, task:, amount:, now:)
        @draft = draft
        @task = task
        @amount = amount.to_i
        @now = now
      end

      def call
        return Result.failure(DraftTasks::WrongState.new(draft, "ready")) unless draft.ready?
        return Result.success(nil) unless amount.positive?

        entry = write_entry
        TaskEvent.track!(task: task, actor: draft.author, kind: "points_awarded", data: { amount: amount, draft_id: draft.id.to_s })
        Result.success(entry)
      end

      private

      attr_reader :draft, :task, :amount, :now

      def write_entry
        PointsLedgerEntry.create!(
          company: draft.company, user: draft.author, task: task, draft_task_id: draft.id,
          amount: amount, kind: "award", week_key: week_key, note: PointsLedgerEntry::ESCROW_NOTE
        )
      rescue StandardError => e
        Rails.logger.error("escrow settle failed for draft #{draft.id}: #{e.class}: #{e.message}")
        raise
      end

      def week_key
        Points::Queries::WeeklyWindow.call(company: draft.company, now: now).key
      end
    end
  end
end
