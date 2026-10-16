module Lists
  module Commands
    class Destroy
      def self.call(list:, actor:)
        new(list: list, actor: actor).call
      end

      def initialize(list:, actor:)
        @list = list
        @actor = actor
      end

      def call
        return Result.failure("list #{list.slug} is already deleted") if list.deleted?

        list.update!(deleted_at: Time.current)
        released = Lists::Services::ReleaseDrafts.for_card(list.id)
        list.comments.from_drafts.delete_all
        list.share_links.active.each(&:revoke!)
        AuditLog.record!(company: list.company, actor: actor, action: "list.deleted", target: list, details: { released: released })
        Result.success(list)
      end

      private

      attr_reader :list, :actor
    end
  end
end
