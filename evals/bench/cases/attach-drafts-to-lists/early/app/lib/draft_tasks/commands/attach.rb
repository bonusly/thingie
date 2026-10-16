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
        return Result.failure(DraftTasks::WrongState.new(draft, "drafting or ready")) if draft.sent?
        return Result.failure("only the author can attach a draft") unless draft.author_id == actor.id
        return Result.success(draft) if draft.list_id == list.id

        shortfall = balance_shortfall
        return Result.failure(shortfall) if shortfall

        previous_list_id = draft.list_id
        draft.update!(list: list, attached_at: now, state: "ready", ready_at: draft.ready_at || now)
        replace_attach_comment(previous_list_id)
        Result.success(draft)
      end

      private

      attr_reader :draft, :list, :actor, :now

      def balance_shortfall
        return nil unless draft.drafting?

        balance = Points::Queries::GivingBalance.call(user: draft.author, company: draft.company, now: now)
        return nil if balance.covers?(draft.points)

        Points::InsufficientBalance.new(requested: draft.points, remaining: balance.remaining)
      end

      def replace_attach_comment(previous_list_id)
        Comment.where(commentable_type: "List", commentable_id: previous_list_id).for_draft(draft).delete_all if previous_list_id

        Comments::Commands::Create.call(
          company: draft.company, author: draft.author, commentable: list,
          attrs: { body: I18n.t("draft_tasks.attached_comment", title: draft.title), draft_task_id: draft.id }
        ).value!
      end
    end
  end
end
