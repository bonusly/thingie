module Sharing
  module Commands
    class CreateShareLink
      def self.call(list:, actor:, ttl: nil, show_drafts: false)
        new(list: list, actor: actor, ttl: ttl, show_drafts: show_drafts).call
      end

      def initialize(list:, actor:, ttl:, show_drafts:)
        @list = list
        @actor = actor
        @ttl = ttl || Rails.application.config.x.share_links.default_ttl
        @show_drafts = show_drafts
      end

      def call
        return Result.failure(Sharing::NotShareable.new(list)) if list.archived?
        return Result.failure(Lists::NotAMember.new(actor, list)) unless list.member?(actor)

        link = ShareLink.create!(
          company: list.company, list: list, created_by: actor, expires_at: ttl.from_now, show_drafts: show_drafts
        )
        AuditLog.record!(company: list.company, actor: actor, action: "share_link.created", target: link)
        Result.success(link)
      end

      private

      attr_reader :list, :actor, :ttl, :show_drafts
    end
  end
end
