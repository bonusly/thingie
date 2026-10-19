module Lists
  module Jobs
    class ConvertDraftTasksJob
      include Sidekiq::Job

      sidekiq_options queue: :default, retry: 5

      def perform(list_id, actor_id)
        list = List.where(id: list_id).first
        return if list.nil? || list.archived?

        actor = User.where(id: actor_id).first

        list.draft_tasks.ready.each do |draft|
          result = Lists::Commands::ConvertDraftTaskComment.call(draft: draft, actor: actor)
          logger.warn("draft #{draft.id} skipped: #{result.error}") if result.failure?
        end
      end
    end
  end
end
