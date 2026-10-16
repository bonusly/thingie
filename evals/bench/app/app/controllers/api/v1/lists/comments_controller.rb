module Api
  module V1
    module Lists
      class CommentsController < BaseController
        def index
          authorize!(list, :comment?)
          comments = Comments::Queries::ListComments.call(commentable: list, since: since)
          render_collection(comments, Comments::Blueprints::CommentBlueprint)
        end

        def create
          authorize!(list, :comment?)
          result = Comments::Commands::Create.call(
            company: current_company, author: current_user, commentable: list, attrs: comment_params
          )
          render_result(result, blueprint: Comments::Blueprints::CommentBlueprint, status: :created)
        end

        private

        def list
          @list ||= ::Lists::Queries::FindList.call(company: current_company, id: params[:list_id])
        end

        def comment_params
          params.require(:comment).permit(:body)
        end

        def since
          params[:since].presence && Time.iso8601(params[:since])
        end
      end
    end
  end
end
