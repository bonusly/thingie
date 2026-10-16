require "rails_helper"

RSpec.describe Connectors::Github::Queries::ListIssues do
  include_context "with a github connector account"

  def issue(id, title: "Issue #{id}", pull: false)
    raw = { "id" => id, "title" => title, "html_url" => "https://github.com/acme/app/issues/#{id}", "updated_at" => "2026-10-15T10:00:00Z", "number" => id, "state" => "open" }
    pull ? raw.merge("pull_request" => {}) : raw
  end

  it "follows pagination and normalizes issues, dropping pull requests" do
    allow(client).to receive(:issues).with(hash_including(cursor: nil)).and_return(Connectors::Page.new(items: [issue(1), issue(2, pull: true)], next_cursor: 2))
    allow(client).to receive(:issues).with(hash_including(cursor: "2")).and_return(Connectors::Page.new(items: [issue(3)], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s)

    expect(result.items.map { |item| item[:external_id] }).to eq(%w[1 3])
    expect(result.items.first).to include(kind: "issue", title: "Issue 1")
    expect(result.pages_fetched).to eq(2)
    expect(result.next_cursor).to be_nil
  end

  it "stops after the page limit and returns the cursor to resume from" do
    allow(client).to receive(:issues) { |cursor:, **| Connectors::Page.new(items: [issue(cursor.to_i + 1)], next_cursor: cursor.to_i + 2) }

    result = described_class.call(account_id: account.id.to_s, cursor: "1")

    expect(result.pages_fetched).to eq(5)
    expect(result.next_cursor).to eq("11")
  end

  it "honours a smaller page budget" do
    allow(client).to receive(:issues) { |cursor:, **| Connectors::Page.new(items: [issue(cursor.to_i + 1)], next_cursor: cursor.to_i + 2) }

    result = described_class.call(account_id: account.id.to_s, cursor: "1", pages: 2)

    expect(result.pages_fetched).to eq(2)
    expect(result.next_cursor).to eq("5")
  end

  it "passes the computed since watermark through" do
    allow(client).to receive(:issues).and_return(Connectors::Page.empty)
    result = described_class.call(account_id: account.id.to_s, since: "2026-10-01T00:00:00Z")
    expect(result.since).to eq(Time.utc(2026, 10, 1))
    expect(client).to have_received(:issues).with(hash_including(since: Time.utc(2026, 10, 1)))
  end

  it "accepts a zoned time for since, as the sync job passes" do
    allow(client).to receive(:issues).and_return(Connectors::Page.empty)
    since = Time.zone.parse("2026-10-02 09:30")
    expect(since).to be_a(ActiveSupport::TimeWithZone)

    result = described_class.call(account_id: account.id.to_s, since: since)

    expect(result.since).to eq(since)
    expect(client).to have_received(:issues).with(hash_including(since: since))
  end

  it "counts since_days back from now" do
    allow(client).to receive(:issues).and_return(Connectors::Page.empty)
    result = described_class.call(account_id: account.id.to_s, since_days: "3")
    expect(result.since).to be_within(5.seconds).of(3.days.ago)
  end

  it "rejects invalid input" do
    expect { described_class.call(account_id: account.id.to_s, per_page: 500) }.to raise_error(Connectors::InvalidInput)
    expect { described_class.call(account_id: account.id.to_s, pages: 6) }.to raise_error(Connectors::InvalidInput)
    expect { described_class.call(per_page: 10) }.to raise_error(Connectors::InvalidInput)
  end
end
