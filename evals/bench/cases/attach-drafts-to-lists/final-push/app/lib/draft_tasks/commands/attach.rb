module DraftTasks
  module Commands
    class Attach
      def self.call(draft:, list:, actor:, now: Time.current)
        new(draft: draft, list: list, actor: actor, now: now).call
      end

      def initialize(draft:, list:, actor:, now:)
        @draft = draft
        @list = list
        @actor = actor
        @now = now
      end

      def call
        return Result.failure("list does not belong to this company") unless list.company_id == draft.company_id
        return Result.failure(Lists::Archived.new(list)) if list.archived?
        return Result.failure("list #{list.slug} has been deleted") if list.deleted?

        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "drafting or ready")) if locked.sent?
          return Result.failure("only the author can attach a draft") unless locked.author_id == actor.id
          return Result.success(locked) if locked.list_id == list.id

          shortfall = balance_shortfall(locked)
          return Result.failure(shortfall) if shortfall

          previous_list_id = locked.list_id
          locked.list = list
          locked.attached_at = now
          locked.drafting? ? locked.mark_ready! : locked.save!
          replace_attach_comment(locked, previous_list_id)
          Result.success(locked)
        end
      rescue DraftTasks::Services::WithLockedDraft::Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :list, :actor, :now

      def balance_shortfall(locked)
        return nil unless locked.drafting?

        balance = Points::Queries::GivingBalance.call(user: locked.author, company: locked.company, now: now)
        return nil if balance.covers?(locked.points)

        Points::InsufficientBalance.new(requested: locked.points, remaining: balance.remaining)
      end

      def replace_attach_comment(locked, previous_list_id)
        Comment.where(commentable_type: "List", commentable_id: previous_list_id).for_draft(locked).delete_all if previous_list_id

        Comments::Commands::Create.call(
          company: locked.company, author: locked.author, commentable: list,
          attrs: { body: I18n.t("draft_tasks.attached_comment", title: locked.title), draft_task_id: locked.id }
        ).value!
      end
    end
  end
end
