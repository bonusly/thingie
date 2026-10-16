module Api
  module V1
    class ListsController < BaseController
      BLUEPRINT = Lists::Blueprints::ListBlueprint

      def index
        lists = Lists::Queries::ListLists.call(
          company: current_company, user: current_user, include_archived: params[:include_archived] == "true"
        )
        render_collection(lists, BLUEPRINT, view: :with_counts)
      end

      def show
        authorize!(list, :show?)
        render json: BLUEPRINT.render(list, view: :with_counts)
      end

      def create
        result = Lists::Commands::Create.call(company: current_company, owner: current_user, attrs: list_params)
        render_result(result, blueprint: BLUEPRINT, status: :created)
      end

      def update
        authorize!(list, :update?)
        render_result(Lists::Commands::Update.call(list: list, actor: current_user, attrs: list_params), blueprint: BLUEPRINT)
      end

      def destroy
        authorize!(list, :destroy?)
        head_result(Lists::Commands::Destroy.call(list: list, actor: current_user))
      end

      def deliver
        authorize!(list, :deliver?)
        render_result(Lists::Commands::Deliver.call(list: list, actor: current_user), blueprint: BLUEPRINT)
      end

      def archive
        authorize!(list, :archive?)
        render_result(Lists::Commands::Archive.call(list: list, actor: current_user), blueprint: BLUEPRINT)
      end

      def restore
        authorize!(list, :restore?)
        list.restore!
        render json: BLUEPRINT.render(list)
      end

      private

      def list
        @list ||= Lists::Queries::FindList.call(company: current_company, id: params[:id])
      end

      def list_params
        params.require(:list).permit(:name, :description, :visibility, :position, member_ids: [])
      end
    end
  end
end
