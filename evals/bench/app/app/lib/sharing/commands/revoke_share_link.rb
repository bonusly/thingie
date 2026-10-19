module Sharing
  module Commands
    class RevokeShareLink
      def self.call(share_link:, actor:)
        new(share_link: share_link, actor: actor).call
      end

      def initialize(share_link:, actor:)
        @share_link = share_link
        @actor = actor
      end

      def call
        return Result.success(share_link) unless share_link.active?
        return Result.failure("only list members can revoke a share link") unless share_link.list.member?(actor)

        share_link.revoke!
        AuditLog.record!(company: share_link.company, actor: actor, action: "share_link.revoked", target: share_link)
        Result.success(share_link)
      end

      private

      attr_reader :share_link, :actor
    end
  end
end
