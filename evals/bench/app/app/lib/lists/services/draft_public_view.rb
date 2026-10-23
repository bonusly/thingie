module Lists
  module Services
    class DraftPublicView
      View = Struct.new(:id, :title, :author_name, :scheduled_for, :attached_at, :points, :state, :draft, keyword_init: true)

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
          attached_at: draft.attached_at,
          points: draft.points,
          state: draft.state,
          draft: draft
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
