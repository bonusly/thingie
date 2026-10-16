module Webhooks
  module Jobs
    class DeliverJob
      include Sidekiq::Job

      sidekiq_options queue: :default, retry: false

      RETRY_BASE_SECONDS = 30

      def perform(delivery_id)
        delivery = WebhookDelivery.where(id: delivery_id).first
        return if delivery.nil? || !delivery.pending?

        delivery.record_attempt!
        status = post(delivery)
        status.between?(200, 299) ? succeed(delivery, status) : fail_or_retry(delivery, status)
      end

      private

      def post(delivery)
        body = delivery.payload.merge("event" => delivery.event).to_json
        signature = OpenSSL::HMAC.hexdigest("SHA256", delivery.webhook.secret, body)
        response = Faraday.post(delivery.webhook.url, body, "Content-Type" => "application/json", "X-Tasker-Signature" => signature)
        response.status
      rescue Faraday::Error
        0
      end

      def succeed(delivery, status)
        delivery.deliver!(status)
        delivery.webhook.record_success!
      end

      def fail_or_retry(delivery, status)
        delivery.webhook.record_failure!
        return self.class.perform_in(RETRY_BASE_SECONDS * delivery.attempts, delivery.id.to_s) unless delivery.exhausted?

        delivery.reject!(status)
      end
    end
  end
end
