require "rails_helper"

RSpec.describe WebhookDelivery do
  let(:delivery) { create(:webhook_delivery) }

  it "starts pending" do
    expect(delivery).to be_pending
  end

  describe "#deliver!" do
    it "records the status and time" do
      delivery.deliver!(204)
      expect(delivery.reload).to be_delivered
      expect(delivery.response_status).to eq(204)
      expect(delivery.delivered_at).to be_present
    end
  end

  describe "#reject!" do
    it "keeps the failing status" do
      delivery.reject!(500)
      expect(delivery.reload).to be_failed
      expect(delivery.response_status).to eq(500)
    end
  end

  describe ".retryable" do
    it "excludes exhausted deliveries" do
      create(:webhook_delivery, :exhausted)
      expect(described_class.retryable.to_a).to eq([delivery])
    end
  end

  describe "#record_attempt!" do
    it "increments attempts and reports exhaustion" do
      (WebhookDelivery::MAX_ATTEMPTS - 1).times { delivery.record_attempt! }
      expect(delivery.reload).not_to be_exhausted
      delivery.record_attempt!
      expect(delivery.reload).to be_exhausted
    end
  end
end
