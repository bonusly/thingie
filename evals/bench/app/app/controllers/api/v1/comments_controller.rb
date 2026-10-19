module Api
  module V1
    class CommentsController < BaseController
      def update
        authorize!(comment, :update?)
        result = Comments::Commands::Update.call(comment: comment, actor: current_user, body: params.require(:comment).require(:body))
        render_result(result, blueprint: Comments::Blueprints::CommentBlueprint)
      end

      def destroy
        authorize!(comment, :destroy?)
        head_result(Comments::Commands::Destroy.call(comment: comment, actor: current_user))
      end

      private

      def comment
        @comment ||= Comment.for_company(current_company).where(id: params[:id]).first || raise(Comments::NotFound, params[:id])
      end
    end
  end
end
