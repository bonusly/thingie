module Points
  module Commands
    class ReleaseStaleReservations
      def self.call(company:)
        new(company: company).call
      end

      def initialize(company:)
        @company = company
      end

      def call
        released = 0
        stale_drafts.each do |draft|
          draft.release_reservation!
          released += 1
        rescue DraftTasks::WrongState
          next
        end
        Result.success(released: released)
      end

      private

      attr_reader :company

      def stale_drafts
        DraftTask.for_company(company).reserving.nin(author_id: active_author_ids)
      end

      def active_author_ids
        company.memberships.active.pluck(:user_id)
      end
    end
  end
end
