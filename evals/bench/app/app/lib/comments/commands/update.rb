module Comments
  module Commands
    class Update
      def self.call(comment:, actor:, body:)
        new(comment: comment, actor: actor, body: body).call
      end

      def initialize(comment:, actor:, body:)
        @comment = comment
        @actor = actor
        @body = body
      end

      def call
        return Result.failure(Comments::NotAuthor.new) unless comment.editable_by?(actor)
        return Result.success(comment) if comment.body == body

        comment.body = body
        comment.edited_at = Time.current
        comment.mentioned_user_ids = Comments::Services::MentionParser.call(company: comment.company, body: body)
        return Result.failure(comment.errors.full_messages) unless comment.save

        Result.success(comment)
      end

      private

      attr_reader :comment, :actor, :body
    end
  end
end
