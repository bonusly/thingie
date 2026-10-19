module Comments
  module Commands
    class Create
      PERMITTED = %i[body draft_task_id].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, author:, commentable:, attrs:)
        @company = company
        @author = author
        @commentable = commentable
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure("cannot comment across companies") unless commentable.company_id == company.id

        comment = Comment.new(attrs.merge(company: company, author: author, commentable: commentable))
        comment.mentioned_user_ids = Comments::Services::MentionParser.call(company: company, body: comment.body)
        return Result.failure(comment.errors.full_messages) unless comment.save

        after_create(comment)
        Result.success(comment)
      end

      private

      attr_reader :company, :author, :commentable, :attrs

      def after_create(comment)
        notify_mentions(comment)
        return unless commentable.is_a?(Task)

        TaskEvent.track!(task: commentable, actor: author, kind: "commented", data: { comment_id: comment.id.to_s })
        WebhookDispatcher.dispatch(company: company, event: "comment.created", payload: { comment_id: comment.id.to_s })
      end

      def notify_mentions(comment)
        comment.mentions.each do |user|
          next if user.id == author.id

          Notifications::Commands::Create.call(
            company: company, recipient: user, kind: "mentioned", subject: comment,
            payload: { excerpt: comment.body.truncate(120), by: author.display_name }
          )
        end
      end
    end
  end
end
