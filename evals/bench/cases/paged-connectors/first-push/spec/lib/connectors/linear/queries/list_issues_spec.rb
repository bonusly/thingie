require "rails_helper"

RSpec.describe Connectors::Linear::Queries::ListIssues do
  include_context "with a linear connector account"

  def node(identifier, team: "ENG")
    { "id" => "lin-#{identifier}", "identifier" => identifier, "title" => "Do #{identifier}", "url" => "https://linear.app/#{identifier}",
      "updatedAt" => "2026-10-15T08:00:00Z", "state" => { "name" => "Backlog" }, "team" => { "key" => team } }
  end

  it "normalizes issues with the identifier in the title" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("ENG-1")], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s)

    expect(result.items.first).to include(external_id: "lin-ENG-1", title: "ENG-1 Do ENG-1", payload: { "state" => "Backlog", "team" => "ENG" })
  end

  it "passes the team key into the GraphQL filter" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("OPS-1", team: "OPS")], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s, team_key: "OPS")

    expect(client).to have_received(:issues).with(hash_including(team_key: "OPS"))
    expect(result.items.map { |item| item[:external_id] }).to eq(["lin-OPS-1"])
  end

  it "passes the cursor as the GraphQL after argument" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [], next_cursor: nil))
    described_class.call(account_id: account.id.to_s, cursor: "abc", first: 10)
    expect(client).to have_received(:issues).with(hash_including(after: "abc", first: 10, team_key: nil))
  end

  it "walks up to the page budget and returns the end cursor" do
    allow(client).to receive(:issues) { |after:, **| Connectors::Page.new(items: [node("ENG-#{after.to_i + 1}")], next_cursor: (after.to_i + 1).to_s) }

    result = described_class.call(account_id: account.id.to_s, pages: 3)

    expect(result.pages_fetched).to eq(3)
    expect(result.next_cursor).to eq("3")
  end

  it "counts since_days back from now" do
    allow(client).to receive(:issues).and_return(Connectors::Page.empty)
    result = described_class.call(account_id: account.id.to_s, since_days: 7)
    expect(result.since).to be_within(5.seconds).of(7.days.ago)
  end
end
