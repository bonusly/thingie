module Lists
  module Commands
    class ConvertDraftTaskComment
      def self.call(draft:, actor:)
        new(draft: draft, actor: actor).call
      end

      def initialize(draft:, actor:)
        @draft = draft
        @actor = actor
      end

      def call
        return Result.failure(DraftTasks::WrongState.new(draft, "ready")) unless draft.ready?

        result = DraftTasks::Commands::SendDraft.call(draft: draft, actor: actor, finalize: false)
        return result if result.failure?

        task = result.value
        comment = build_comment(task)
        draft.mark_sent!(task)
        notify(task, comment)
        Result.success(task: task, comment: comment)
      end

      private

      attr_reader :draft, :actor

      def build_comment(task)
        return nil if draft.note.blank?

        Comments::Commands::Create.call(
          company: draft.company, author: draft.author, commentable: task,
          attrs: { body: draft.note, draft_task_id: draft.id }
        ).value!
      end

      def notify(task, comment)
        return if actor.nil? || actor.id == draft.author_id

        Notifications::Commands::Create.call(
          company: draft.company, recipient: draft.author, kind: "draft_sent", subject: task,
          payload: { title: task.title, sent_by: actor.display_name, comment_id: comment&.id&.to_s }
        )
      end
    end
  end
end
