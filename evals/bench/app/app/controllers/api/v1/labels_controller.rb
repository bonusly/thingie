module Api
  module V1
    class LabelsController < BaseController
      def index
        render json: Label.for_company(current_company).alphabetical.map { |label| serialize(label) }
      end

      def create
        label = Label.create!(label_params.merge(company: current_company))
        render json: serialize(label), status: :created
      end

      def update
        label.update!(label_params)
        render json: serialize(label)
      end

      def destroy
        require_admin!
        Task.for_company(current_company).where(label_ids: label.id).pull(label_ids: label.id)
        label.destroy!
        head :no_content
      end

      private

      def label
        @label ||= Label.for_company(current_company).find(params[:id])
      end

      def label_params
        params.require(:label).permit(:name, :color)
      end

      def serialize(label)
        { id: label.id.to_s, name: label.name, slug: label.slug, color: label.color, task_count: label.task_count }
      end
    end
  end
end
