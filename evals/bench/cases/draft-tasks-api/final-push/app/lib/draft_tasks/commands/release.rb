module DraftTasks
  module Commands
    class Release
      FINAL_EDITS = DraftTasks::Commands::MarkReady::FINAL_EDITS

      def self.call(draft:, actor:, edits: {})
        new(draft: draft, actor: actor, edits: edits).call
      end

      def initialize(draft:, actor:, edits:)
        @draft = draft
        @actor = actor
        @edits = edits.to_h.symbolize_keys.slice(*FINAL_EDITS)
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "ready")) if locked.sent?
          return Result.failure("only the author can release a draft") unless allowed?(locked)
          return Result.success(locked) if locked.drafting?

          locked.resume_drafting!
          return Result.failure(locked.errors.full_messages) unless locked.update(edits)

          Result.success(locked)
        end
      rescue DraftTasks::Commands::SendDraft::Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :actor, :edits

      def allowed?(locked)
        locked.author_id == actor.id || actor.admin_of?(locked.company)
      end
    end
  end
end
