module Lists
  module Commands
    class Deliver
      def self.call(list:, actor:)
        new(list: list, actor: actor).call
      end

      def initialize(list:, actor:)
        @list = list
        @actor = actor
      end

      def call
        return Result.failure(Lists::Archived.new(list)) if list.archived?
        return Result.failure(Lists::NotAMember.new(actor, list)) unless list.member?(actor)

        list.update!(delivered_at: Time.current)
        notify_members
        enqueue_draft_conversion
        WebhookDispatcher.dispatch(company: list.company, event: "list.delivered", payload: { list_id: list.id.to_s })
        Result.success(list)
      end

      private

      attr_reader :list, :actor

      def notify_members
        list.members.each do |member|
          next if member.id == actor.id

          Notifications::Commands::Create.call(
            company: list.company, recipient: member, kind: "list_delivered", subject: list,
            payload: { name: list.name, delivered_by: actor.display_name }
          )
        end
      end

      def enqueue_draft_conversion
        return unless list.draft_tasks.ready.exists?

        Lists::Jobs::ConvertDraftTasksJob.perform_async(list.id.to_s, actor.id.to_s)
      end
    end
  end
end
