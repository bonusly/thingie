module Api
  module V1
    module DraftTasks
      class CommentsController < BaseController
        include DraftTaskScoped
        include RequiresFeature

        before_action { require_feature!(:draft_tasks) }

        def index
          authorize!(draft, :show?)
          comments = ::DraftTasks::Queries::ListDraftComments.call(draft: draft)
          render json: ::DraftTasks::Blueprints::CommentBlueprint.render(comments)
        end

        private

        def draft
          @draft ||= draft_tasks.find(params[:draft_task_id])
        end
      end
    end
  end
end
