module Api
  module V1
    class DraftTasksController < BaseController
      BLUEPRINT = DraftTasks::Blueprints::DraftTaskBlueprint
      MAX_RESERVATIONS = 100

      def index
        drafts = DraftTasks::Queries::ListDrafts.call(
          company: current_company, author: current_user, state: params[:state], list_id: params[:list_id]
        )
        render_collection(drafts, BLUEPRINT)
      end

      def reservations
        drafts = DraftTasks::Queries::ListReservations.call(
          company: current_company, author: current_user, limit: reservation_limit
        )
        render json: BLUEPRINT.render(drafts)
      end

      def show
        authorize!(draft, :show?)
        render json: BLUEPRINT.render(draft)
      end

      def create
        list = Lists::Queries::FindList.call(company: current_company, id: params.require(:list_id))
        authorize!(DraftTask.new(company: current_company, list: list), :create?)
        result = DraftTasks::Commands::Create.call(company: current_company, author: current_user, list: list, attrs: draft_params)
        render_result(result, blueprint: BLUEPRINT, status: :created)
      end

      def update
        authorize!(draft, :update?)
        render_result(DraftTasks::Commands::Update.call(draft: draft, actor: current_user, attrs: draft_params), blueprint: BLUEPRINT)
      end

      def destroy
        authorize!(draft, :destroy?)
        head_result(DraftTasks::Commands::Destroy.call(draft: draft, actor: current_user))
      end

      def mark_ready
        authorize!(draft, :mark_ready?)
        render_result(DraftTasks::Commands::MarkReady.call(draft: draft, actor: current_user), blueprint: BLUEPRINT)
      end

      def release
        authorize!(draft, :release?)
        render_result(DraftTasks::Commands::Release.call(draft: draft, actor: current_user), blueprint: BLUEPRINT)
      end

      def send_now
        authorize!(draft, :send_now?)
        result = DraftTasks::Commands::SendDraft.call(draft: draft, actor: current_user)
        render_result(result, blueprint: Tasks::Blueprints::TaskBlueprint, status: :created)
      end

      private

      def draft
        @draft ||= DraftTasks::Queries::FindDraft.call(company: current_company, id: params[:id])
      end

      def reservation_limit
        (params[:limit].presence || DraftTasks::Queries::ListReservations::DEFAULT_LIMIT).to_s.to_i.clamp(1, MAX_RESERVATIONS)
      end

      def draft_params
        params.require(:draft_task).permit(
          :title, :description, :note, :points, :due_on, :scheduled_for, :visibility, assignee_ids: [], label_ids: []
        )
      end
    end
  end
end
