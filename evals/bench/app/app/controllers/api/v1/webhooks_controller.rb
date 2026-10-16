module Api
  module V1
    class WebhooksController < BaseController
      before_action :require_admin!

      def index
        render json: current_company.webhooks.order(created_at: :desc).map { |webhook| serialize(webhook) }
      end

      def show
        render json: serialize(webhook).merge(recent_deliveries: recent_deliveries)
      end

      def create
        webhook = current_company.webhooks.create!(webhook_params)
        render json: serialize(webhook).merge(secret: webhook.secret), status: :created
      end

      def update
        webhook.update!(webhook_params)
        render json: serialize(webhook)
      end

      def destroy
        webhook.destroy!
        head :no_content
      end

      private

      def webhook
        @webhook ||= current_company.webhooks.find(params[:id])
      end

      def webhook_params
        params.require(:webhook).permit(:url, :active, events: [])
      end

      def serialize(webhook)
        { id: webhook.id.to_s, url: webhook.url, events: webhook.events, active: webhook.active, failure_count: webhook.failure_count }
      end

      def recent_deliveries
        webhook.deliveries.order(created_at: :desc).limit(10).map do |delivery|
          { id: delivery.id.to_s, event: delivery.event, state: delivery.state, status: delivery.response_status, attempts: delivery.attempts }
        end
      end
    end
  end
end
