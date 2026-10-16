module DraftTasks
  module Commands
    class Detach
      def self.call(draft:, actor:)
        new(draft: draft, actor: actor).call
      end

      def initialize(draft:, actor:)
        @draft = draft
        @actor = actor
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "drafting or ready")) if locked.sent?
          return Result.failure("only the author or an admin can detach a draft") unless allowed?(locked)
          return Result.success(locked) unless locked.attached?

          previous_list_id = locked.list_id
          locked.resume_drafting! if locked.ready?
          locked.update!(list: nil, attached_at: nil)
          Comment.where(commentable_type: "List", commentable_id: previous_list_id).for_draft(locked).delete_all
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
