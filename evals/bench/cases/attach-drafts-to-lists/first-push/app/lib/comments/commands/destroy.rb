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
        return release_draft if comment.attaches_draft?

        comment.destroy!
        Result.success(comment)
      end

      private

      attr_reader :comment, :actor

      def allowed?
        comment.editable_by?(actor) || actor.admin_of?(comment.company)
      end

      def release_draft
        draft = comment.draft
        if draft.nil?
          comment.destroy!
          return Result.success(comment)
        end

        result = DraftTasks::Commands::Detach.call(draft: draft, actor: actor)
        return result if result.failure?

        Result.success(comment)
      end
    end
  end
end
