module Lists
  module Jobs
    class ConvertDraftTasksJob
      include Sidekiq::Job

      sidekiq_options queue: :default, retry: 5

      def perform(list_id, actor_id)
        list = List.where(id: list_id).first
        return if list.nil? || list.archived? || list.deleted?

        actor = User.where(id: actor_id).first

        list.draft_tasks.ready.each do |draft|
          result = Lists::Commands::ConvertDraftTaskComment.call(draft: draft, actor: actor)
          next if result.success?

          logger.warn("draft #{draft.id} skipped: #{result.error}")
          notify_failure(list, draft, result.error)
        end
      end

      private

      def notify_failure(list, draft, error)
        Notifications::Commands::Create.call(
          company: list.company, recipient: draft.author, kind: "draft_conversion_failed", subject: draft,
          payload: { title: draft.title, name: list.name, reason: error.to_s }
        )
      end
    end
  end
end
