module Lists
  module Services
    class DraftPublicView
      View = Struct.new(:id, :title, :author_name, :scheduled_for, :points, :state, :task_id, keyword_init: true)

      def self.call(draft:, share_link:)
        new(draft: draft, share_link: share_link).call
      end

      def initialize(draft:, share_link:)
        @draft = draft
        @share_link = share_link
      end

      def call
        return nil unless visible?

        draft.sent? ? sent_view : pending_view
      end

      private

      attr_reader :draft, :share_link

      def visible?
        return false unless share_link.show_drafts && share_link.list_id == draft.list_id

        draft.ready? || (draft.sent? && draft.sent_task_id.present?)
      end

      def pending_view
        View.new(
          id: draft.id.to_s,
          title: draft.title,
          author_name: draft.private? ? nil : draft.author.display_name,
          scheduled_for: draft.scheduled_for,
          points: draft.points,
          state: draft.state,
          task_id: nil
        )
      end

      def sent_view
        View.new(
          id: draft.id.to_s,
          title: draft.title,
          author_name: draft.author.display_name,
          scheduled_for: draft.sent_at,
          points: draft.points,
          state: draft.state,
          task_id: draft.sent_task_id.to_s
        )
      end
    end
  end
end
