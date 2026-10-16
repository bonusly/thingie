module Sharing
  module Queries
    class PublicList
      PublicView = Struct.new(:list, :tasks, :drafts, :share_link, keyword_init: true)

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

        list.draft_tasks.ready.filter_map do |draft|
          Lists::Services::DraftPublicView.call(draft: draft, share_link: share_link)
        end
      end
    end
  end
end
