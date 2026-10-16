require "rails_helper"

RSpec.describe Connectors::Commands::ImportItems do
  let(:account) { create(:connector_account) }

  def item(id, updated_at: Time.utc(2026, 10, 15))
    { external_id: id, kind: "issue", title: "Issue #{id}", url: "https://example.test/#{id}", external_updated_at: updated_at, payload: {} }
  end

  it "creates new items and reports counts" do
    result = described_class.call(account: account, items: [item("1"), item("2")])

    expect(result.value).to have_attributes(created: 2, updated: 0, skipped: 0)
    expect(account.external_items.count).to eq(2)
  end

  it "updates items with a newer timestamp and skips stale ones" do
    create(:external_item, company: account.company, connector_account: account, external_id: "1", title: "old", external_updated_at: Time.utc(2026, 10, 10))

    result = described_class.call(account: account, items: [item("1", updated_at: Time.utc(2026, 10, 12)), item("1", updated_at: Time.utc(2026, 10, 1))])

    expect(result.value).to have_attributes(created: 0, updated: 1, skipped: 1)
    expect(account.external_items.first.title).to eq("Issue 1")
  end
end
