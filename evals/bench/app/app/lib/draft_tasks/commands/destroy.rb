module DraftTasks
  module Commands
    class Destroy
      def self.call(draft:, actor:)
        new(draft: draft, actor: actor).call
      end

      def initialize(draft:, actor:)
        @draft = draft
        @actor = actor
      end

      def call
        return Result.failure(DraftTasks::WrongState.new(draft, "drafting or ready")) if draft.sent?
        return Result.failure("only the author can delete a draft") unless draft.author_id == actor.id

        draft.destroy!
        Result.success(draft)
      end

      private

      attr_reader :draft, :actor
    end
  end
end
