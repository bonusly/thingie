module Comments
  module Commands
    class Destroy
      def self.call(comment:, actor:)
        new(comment: comment, actor: actor).call
      end

      def initialize(comment:, actor:)
        @comment = comment
        @actor = actor
      end

      def call
        return Result.failure(Comments::NotAuthor.new) unless allowed?

        comment.destroy!
        Result.success(comment)
      end

      private

      attr_reader :comment, :actor

      def allowed?
        comment.editable_by?(actor) || actor.admin_of?(comment.company)
      end
    end
  end
end
