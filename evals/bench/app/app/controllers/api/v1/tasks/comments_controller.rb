module Api
  module V1
    module Tasks
      class CommentsController < BaseController
        def index
          authorize!(task, :show?)
          comments = Comments::Queries::ListComments.call(commentable: task, since: since)
          render_collection(comments, Comments::Blueprints::CommentBlueprint)
        end

        def create
          authorize!(task, :show?)
          result = Comments::Commands::Create.call(
            company: current_company, author: current_user, commentable: task, attrs: comment_params
          )
          render_result(result, blueprint: Comments::Blueprints::CommentBlueprint, status: :created)
        end

        private

        def task
          @task ||= ::Tasks::Queries::FindTask.call(company: current_company, id: params[:task_id])
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
