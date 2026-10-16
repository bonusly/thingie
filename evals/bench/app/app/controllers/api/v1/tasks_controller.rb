module Api
  module V1
    class TasksController < BaseController
      def index
        tasks = Tasks::Queries::ListTasks.call(company: current_company, user: current_user, filters: filters)
        render_collection(tasks, Tasks::Blueprints::TaskBlueprint)
      end

      def show
        authorize!(task, :show?)
        render json: Tasks::Blueprints::TaskBlueprint.render(task, view: :detailed)
      end

      def create
        list = Lists::Queries::FindList.call(company: current_company, id: params.require(:list_id))
        authorize!(Task.new(company: current_company, list: list), :create?)
        result = Tasks::Commands::Create.call(company: current_company, author: current_user, list: list, attrs: task_params)
        render_result(result, blueprint: Tasks::Blueprints::TaskBlueprint, status: :created)
      end

      def update
        authorize!(task, :update?)
        render_result(Tasks::Commands::Update.call(task: task, actor: current_user, attrs: task_params), blueprint: Tasks::Blueprints::TaskBlueprint)
      end

      def destroy
        authorize!(task, :destroy?)
        head_result(Tasks::Commands::Archive.call(task: task, actor: current_user))
      end

      def complete
        authorize!(task, :complete?)
        render_result(Tasks::Commands::Complete.call(task: task, actor: current_user), blueprint: Tasks::Blueprints::TaskBlueprint)
      end

      def reopen
        authorize!(task, :reopen?)
        render_result(Tasks::Commands::Reopen.call(task: task, actor: current_user), blueprint: Tasks::Blueprints::TaskBlueprint)
      end

      def archive
        authorize!(task, :archive?)
        render_result(Tasks::Commands::Archive.call(task: task, actor: current_user), blueprint: Tasks::Blueprints::TaskBlueprint)
      end

      def assign
        authorize!(task, :assign?)
        result = Tasks::Commands::Assign.call(task: task, actor: current_user, assignee_ids: params.fetch(:assignee_ids, []))
        render_result(result, blueprint: Tasks::Blueprints::TaskBlueprint)
      end

      private

      def task
        @task ||= Tasks::Queries::FindTask.call(company: current_company, id: params[:id])
      end

      def task_params
        params.require(:task).permit(:title, :description, :due_on, :points, :position, assignee_ids: [], label_ids: [])
      end

      def filters
        params.permit(*Tasks::Queries::ListTasks::FILTERS.excluding(:label_ids), label_ids: []).to_h
      end
    end
  end
end
