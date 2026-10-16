module Sharing
  module Queries
    class PublicList
      PublicView = Struct.new(:list, :tasks, :drafts, :share_link, keyword_init: true)
      SENT_WINDOW = 7.days

      def self.call(share_link:)
        new(share_link: share_link).call
      end

      def initialize(share_link:)
        @share_link = share_link
      end

      def call
        PublicView.new(list: list, tasks: tasks, drafts: drafts, share_link: share_link)
      end

      private

      attr_reader :share_link

      def list
        share_link.list
      end

      def tasks
        list.tasks.not_archived.ordered.to_a
      end

      def drafts
        return [] unless share_link.show_drafts

        draft_scope.filter_map do |draft|
          Lists::Services::DraftPublicView.call(draft: draft, share_link: share_link)
        end
      end

      def draft_scope
        list.draft_tasks.any_of({ state: "ready" }, { state: "sent", :sent_at.gte => SENT_WINDOW.ago })
            .order(sent_at: :desc, ready_at: :desc)
      end
    end
  end
end
