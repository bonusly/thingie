require "rails_helper"

RSpec.describe Connectors::Github::Queries::ListPullRequests do
  include_context "with a github connector account"

  def pull(id)
    { "id" => id, "title" => "PR #{id}", "html_url" => "https://github.com/acme/app/pull/#{id}", "updated_at" => "2026-10-15T10:00:00Z",
      "number" => id, "state" => "open", "draft" => false }
  end

  it "normalizes pull requests" do
    allow(client).to receive(:pull_requests).and_return(Connectors::Page.new(items: [pull(1)], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s)

    expect(result.items.first).to include(external_id: "1", kind: "pull_request", title: "PR 1", payload: hash_including("draft" => false))
    expect(result.next_cursor).to be_nil
  end

  it "walks pages until the limit and hands back the cursor" do
    allow(client).to receive(:pull_requests) { |cursor:, **| Connectors::Page.new(items: [pull(cursor.to_i + 1)], next_cursor: cursor.to_i + 2) }

    result = described_class.call(account_id: account.id.to_s, cursor: "1", pages: 3)

    expect(result.pages_fetched).to eq(3)
    expect(result.next_cursor).to eq("7")
    expect(result.items.size).to eq(3)
  end

  it "passes since_days through to the watermark" do
    allow(client).to receive(:pull_requests).and_return(Connectors::Page.empty)
    result = described_class.call(account_id: account.id.to_s, since_days: 2)
    expect(result.since).to be_within(5.seconds).of(2.days.ago)
  end
end
