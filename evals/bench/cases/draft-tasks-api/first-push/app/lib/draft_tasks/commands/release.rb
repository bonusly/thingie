module DraftTasks
  module Commands
    class Release
      def self.call(draft:, actor:, edits: {})
        new(draft: draft, actor: actor, edits: edits).call
      end

      def initialize(draft:, actor:, edits:)
        @draft = draft
        @actor = actor
        @edits = edits.to_h.symbolize_keys
      end

      def call
        return Result.failure(DraftTasks::WrongState.new(draft, "ready")) if draft.sent?
        return Result.failure("only the author can release a draft") unless allowed?
        return Result.success(draft) if draft.drafting?

        draft.assign_attributes(edits)
        return Result.failure(draft.errors.full_messages) unless draft.valid?

        draft.update(state: "drafting", ready_at: nil, points_reserved_at: nil)
        Result.success(draft)
      end

      private

      attr_reader :draft, :actor, :edits

      def allowed?
        draft.author_id == actor.id || actor.admin_of?(draft.company)
      end
    end
  end
end
