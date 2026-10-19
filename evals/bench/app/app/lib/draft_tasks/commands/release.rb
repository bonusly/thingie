module DraftTasks
  module Commands
    class Release
      def self.call(draft:, actor:)
        new(draft: draft, actor: actor).call
      end

      def initialize(draft:, actor:)
        @draft = draft
        @actor = actor
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "ready")) if locked.sent?
          return Result.failure("only the author can release a draft") unless allowed?(locked)
          return Result.success(locked) if locked.drafting?

          locked.resume_drafting!
          Result.success(locked)
        end
      rescue DraftTasks::Services::WithLockedDraft::Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :actor

      def allowed?(locked)
        locked.author_id == actor.id || actor.admin_of?(locked.company)
      end
    end
  end
end
