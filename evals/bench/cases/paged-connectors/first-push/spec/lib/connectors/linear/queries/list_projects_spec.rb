require "rails_helper"

RSpec.describe Connectors::Linear::Queries::ListProjects do
  include_context "with a linear connector account"

  def project(id, updated_at: "2026-10-15T08:00:00Z")
    { "id" => "proj-#{id}", "name" => "Project #{id}", "url" => "https://linear.app/project/#{id}", "updatedAt" => updated_at,
      "state" => "started", "progress" => 0.5 }
  end

  it "normalizes projects updated inside the window" do
    allow(client).to receive(:projects).and_return(Connectors::Page.new(items: [project(1)], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s, since: "2026-10-01T00:00:00Z")

    expect(result.items.first).to include(external_id: "proj-1", kind: "project", title: "Project 1", payload: { "state" => "started", "progress" => 0.5 })
  end

  it "stops paging once a page contains anything older than the watermark" do
    allow(client).to receive(:projects).with(hash_including(after: nil)).and_return(
      Connectors::Page.new(items: [project(1), project(2, updated_at: "2026-09-01T00:00:00Z")], next_cursor: "c2")
    )

    result = described_class.call(account_id: account.id.to_s, since: "2026-10-01T00:00:00Z")

    expect(result.items.map { |item| item[:external_id] }).to eq(["proj-1"])
    expect(result.pages_fetched).to eq(1)
    expect(client).to have_received(:projects).once
  end

  it "respects the page budget" do
    allow(client).to receive(:projects) { |after:, **| Connectors::Page.new(items: [project(after.to_i + 1)], next_cursor: (after.to_i + 1).to_s) }

    result = described_class.call(account_id: account.id.to_s, since: "2026-10-01T00:00:00Z", pages: 2)

    expect(result.pages_fetched).to eq(2)
    expect(result.next_cursor).to eq("2")
  end
end
