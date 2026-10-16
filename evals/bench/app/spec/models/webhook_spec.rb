require "rails_helper"

RSpec.describe Webhook do
  it "requires https urls" do
    expect(build(:webhook, url: "http://insecure.example.test")).not_to be_valid
  end

  it "rejects unknown events" do
    webhook = build(:webhook, events: %w[task.created task.exploded])
    expect(webhook).not_to be_valid
    expect(webhook.errors[:events]).to be_present
  end

  it "generates a secret on create" do
    expect(create(:webhook).secret).to be_present
  end

  describe ".subscribed_to" do
    it "returns active webhooks listening for the event" do
      listening = create(:webhook, events: %w[task.completed])
      create(:webhook, events: %w[task.created])
      create(:webhook, :inactive, events: %w[task.completed])

      expect(described_class.subscribed_to("task.completed").to_a).to eq([listening])
    end
  end

  describe "#record_failure!" do
    it "deactivates after repeated failures" do
      webhook = create(:webhook, :flaky)
      webhook.record_failure!
      expect(webhook.reload.active).to be(false)
    end

    it "resets the counter on success" do
      webhook = create(:webhook, :flaky)
      webhook.record_success!
      expect(webhook.reload.failure_count).to eq(0)
    end
  end
end
