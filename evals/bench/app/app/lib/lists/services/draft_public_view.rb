module Lists
  module Services
    class DraftPublicView
      View = Struct.new(:id, :title, :author_name, :scheduled_for, :points, :state, keyword_init: true)

      def self.call(draft:, share_link:)
        new(draft: draft, share_link: share_link).call
      end

      def initialize(draft:, share_link:)
        @draft = draft
        @share_link = share_link
      end

      def call
        return nil unless visible?

        View.new(
          id: draft.id.to_s,
          title: draft.title,
          author_name: author_name,
          scheduled_for: draft.scheduled_for,
          points: draft.points,
          state: draft.state
        )
      end

      private

      attr_reader :draft, :share_link

      def visible?
        share_link.show_drafts && share_link.list_id == draft.list_id && !draft.sent?
      end

      def author_name
        return nil if draft.private?

        draft.author.display_name
      end
    end
  end
end
