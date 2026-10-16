module DraftTasks
  module Jobs
    class SendScheduledDraftsJob
      include Sidekiq::Job

      sidekiq_options queue: :default, retry: 3

      def perform(now_iso = nil)
        now = now_iso ? Time.iso8601(now_iso) : Time.current

        DraftTask.ready.scheduled_before(now).each do |draft|
          result = DraftTasks::Commands::SendDraft.call(draft: draft, actor: nil)
          logger.warn("draft #{draft.id} not sent: #{result.error}") if result.failure?
        end
      end
    end
  end
end
