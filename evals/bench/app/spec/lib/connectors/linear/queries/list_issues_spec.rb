require "rails_helper"

RSpec.describe Connectors::Linear::Queries::ListIssues do
  include_context "with a company and members"

  let(:account) { create(:connector_account, :linear, company: company, user: member, last_synced_at: 1.day.ago) }
  let(:client) { instance_double(Connectors::Linear::Client) }

  before { allow(Connectors::Linear::Client).to receive(:new).with(account).and_return(client) }

  def node(identifier, team: "ENG")
    { "id" => "lin-#{identifier}", "identifier" => identifier, "title" => "Do #{identifier}", "url" => "https://linear.app/#{identifier}",
      "updatedAt" => "2026-10-15T08:00:00Z", "state" => { "name" => "Backlog" }, "team" => { "key" => team } }
  end

  it "normalizes issues with the identifier in the title" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("ENG-1")], next_cursor: nil))

    result = described_class.call(account_id: account.id.to_s)

    expect(result.items.first).to include(external_id: "lin-ENG-1", title: "ENG-1 Do ENG-1", payload: { "state" => "Backlog", "team" => "ENG" })
  end

  it "filters by team key when given" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("ENG-1"), node("OPS-1", team: "OPS")], next_cursor: nil))
    result = described_class.call(account_id: account.id.to_s, team_key: "OPS")
    expect(result.items.map { |item| item[:external_id] }).to eq(["lin-OPS-1"])
  end

  it "passes the cursor as the GraphQL after argument" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [], next_cursor: nil))
    described_class.call(account_id: account.id.to_s, cursor: "abc", first: 10)
    expect(client).to have_received(:issues).with(hash_including(after: "abc", first: 10))
  end
end
