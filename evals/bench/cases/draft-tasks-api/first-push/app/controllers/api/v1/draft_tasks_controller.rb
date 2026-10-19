module Api
  module V1
    class DraftTasksController < BaseController
      include DraftTaskScoped
      include GuardsWritableKeys
      include RequiresFeature

      BLUEPRINT = ::DraftTasks::Blueprints::DraftTaskBlueprint
      TASK_BLUEPRINT = Tasks::Blueprints::TaskBlueprint

      before_action { require_feature!(:draft_tasks) }
      before_action :guard_draft_keys!, only: %i[create update]

      def index
        drafts = ::DraftTasks::Queries::ListDrafts.call(
          company: current_company, author: current_user, state: params[:state], list_id: params[:list_id]
        )
        render_collection(drafts, BLUEPRINT)
      end

      def show
        authorize!(draft, :show?)
        render json: BLUEPRINT.render(draft)
      end

      def create
        list = Lists::Queries::FindList.call(company: current_company, id: params.require(:list_id))
        authorize!(DraftTask.new(company: current_company, list: list), :create?)
        result = ::DraftTasks::Commands::Create.call(company: current_company, author: current_user, list: list, attrs: draft_params)
        render_result(result, blueprint: BLUEPRINT, status: :created)
      end

      def update
        authorize!(draft, :update?)
        render_result(::DraftTasks::Commands::Update.call(draft: draft, actor: current_user, attrs: draft_params), blueprint: BLUEPRINT)
      end

      def destroy
        authorize!(draft, :destroy?)
        head_result(::DraftTasks::Commands::Destroy.call(draft: draft, actor: current_user))
      end

      def mark_ready
        authorize!(draft, :mark_ready?)
        result = ::DraftTasks::Commands::MarkReady.call(draft: draft, actor: current_user, edits: final_edits)
        render_result(result, blueprint: BLUEPRINT)
      end

      def release
        authorize!(draft, :release?)
        result = ::DraftTasks::Commands::Release.call(draft: draft, actor: current_user, edits: final_edits)
        render_result(result, blueprint: BLUEPRINT)
      end

      def send_now
        authorize!(draft, :send_now?)
        result = ::DraftTasks::Commands::SendDraft.call(draft: draft, actor: current_user, edits: final_edits)
        render_result(result, blueprint: TASK_BLUEPRINT, status: :created)
      end

      private

      def draft
        @draft ||= draft_tasks.find(params[:id])
      end

      def guard_draft_keys!
        guard_writable_keys!(params.fetch(:draft_task, {}))
      end

      def draft_params
        params.require(:draft_task).permit(
          :title, :description, :note, :points, :due_on, :scheduled_for, :visibility, assignee_ids: [], label_ids: []
        )
      end

      def final_edits
        params.fetch(:draft_task, {}).permit!.to_h
      end
    end
  end
end
