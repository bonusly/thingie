module DraftTasks
  module Queries
    class ListDraftComments
      LIMIT = 50

      def self.call(draft:)
        new(draft: draft).call
      end

      def initialize(draft:)
        @draft = draft
      end

      def call
        return Comment.none if draft.sent_task_id.nil?

        Comment.where(commentable_type: "Task", commentable_id: draft.sent_task_id).chronological.limit(LIMIT)
      end

      private

      attr_reader :draft
    end
  end
end
