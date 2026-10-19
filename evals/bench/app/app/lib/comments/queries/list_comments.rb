module Comments
  module Queries
    class ListComments
      def self.call(commentable:, since: nil)
        new(commentable: commentable, since: since).call
      end

      def initialize(commentable:, since:)
        @commentable = commentable
        @since = since
      end

      def call
        scope = Comment.where(commentable_type: commentable.class.name, commentable_id: commentable.id)
        scope = scope.where(:created_at.gt => since) if since
        scope.chronological
      end

      private

      attr_reader :commentable, :since
    end
  end
end
