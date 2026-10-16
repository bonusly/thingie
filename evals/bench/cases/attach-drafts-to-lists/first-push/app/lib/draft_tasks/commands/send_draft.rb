module DraftTasks
  module Commands
    class SendDraft
      def self.call(draft:, actor:)
        new(draft: draft, actor: actor).call
      end

      def initialize(draft:, actor:)
        @draft = draft
        @actor = actor
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "ready")) unless locked.may_mark_sent?
          return Result.failure(DraftTasks::NotAttached.new(locked)) if locked.list.nil? || locked.list.deleted?

          result = create_task(locked)
          return result if result.failure?

          task = result.value
          locked.mark_sent!(task)
          notify(locked, task)
          Result.success(task)
        end
      rescue DraftTasks::Services::WithLockedDraft::Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :actor

      def create_task(locked)
        Tasks::Commands::Create.call(
          company: locked.company, author: locked.author, list: locked.list, attrs: locked.task_attributes
        )
      end

      def notify(locked, task)
        return if actor.nil? || actor.id == locked.author_id

        Notifications::Commands::Create.call(
          company: locked.company, recipient: locked.author, kind: "draft_sent", subject: task,
          payload: { title: task.title, sent_by: actor.display_name }
        )
      end
    end
  end
end
