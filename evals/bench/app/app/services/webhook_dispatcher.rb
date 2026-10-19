class WebhookDispatcher
  def self.dispatch(company:, event:, payload:)
    new(company: company, event: event, payload: payload).dispatch
  end

  def initialize(company:, event:, payload:)
    @company = company
    @event = event
    @payload = payload
  end

  def dispatch
    Webhook.for_company(company).subscribed_to(event).map do |webhook|
      delivery = WebhookDelivery.create!(webhook: webhook, event: event, payload: payload.stringify_keys)
      Webhooks::Jobs::DeliverJob.perform_async(delivery.id.to_s)
      delivery
    end
  end

  private

  attr_reader :company, :event, :payload
end
