module DraftTasks
  module Commands
    class SendDraft
      module Lock
        class Busy < DraftTasks::Error
          def initialize(key)
            super("draft lock #{key} is held by another process")
          end
        end
      end

      def self.call(draft:, actor:, edits: {}, finalize: true)
        new(draft: draft, actor: actor, edits: edits, finalize: finalize).call
      end

      def initialize(draft:, actor:, edits:, finalize:)
        @draft = draft
        @actor = actor
        @edits = edits.to_h.symbolize_keys
        @finalize = finalize
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "ready")) unless locked.ready?
          return Result.failure(locked.errors.full_messages) unless locked.update(edits)

          result = create_task(locked)
          return result if result.failure?

          task = result.value
          locked.attachment&.update!(task_id: task.id, draft_task_id: nil)
          return Result.success(task) unless finalize

          locked.mark_sent!(task)
          notify(locked, task)
          Result.success(task)
        end
      rescue Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :actor, :edits, :finalize

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
