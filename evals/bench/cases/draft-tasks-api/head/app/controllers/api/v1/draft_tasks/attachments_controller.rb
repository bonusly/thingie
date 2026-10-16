module Api
  module V1
    module DraftTasks
      class AttachmentsController < BaseController
        include DraftTaskScoped
        include RequiresFeature

        before_action { require_feature!(:draft_tasks) }

        def update
          authorize!(draft, :update?)
          result = ::DraftTasks::Commands::ReplaceAttachment.call(
            draft: draft, actor: current_user, attachment_id: params.require(:attachment_id)
          )
          return render_attachment_failure(result.error) if result.failure?

          render json: ::DraftTasks::Blueprints::DraftTaskBlueprint.render(result.value)
        end

        private

        def draft
          @draft ||= draft_tasks.find(params[:draft_task_id])
        end

        def render_attachment_failure(error)
          raise error if error.is_a?(Exception)

          render json: { errors: Array(error) }, status: :unprocessable_entity
        end
      end
    end
  end
end
