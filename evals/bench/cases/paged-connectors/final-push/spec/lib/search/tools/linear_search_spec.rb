require "rails_helper"

RSpec.describe Search::Tools::LinearSearch do
  include_context "with a linear connector account"

  def node(identifier, team: "ENG")
    { "id" => "lin-#{identifier}", "identifier" => identifier, "title" => "Do #{identifier}", "url" => "https://linear.app/#{identifier}",
      "updatedAt" => "2026-10-15T08:00:00Z", "state" => { "name" => "Backlog" }, "team" => { "key" => team } }
  end

  it "passes the team key and cursor into the query" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("OPS-1", team: "OPS")], next_cursor: "end"))

    result = described_class.call(company: company, user: member, team_key: "OPS", cursor: "start")

    expect(client).to have_received(:issues).with(hash_including(team_key: "OPS", after: "start"))
    expect(result).to have_attributes(provider: "linear", next_cursor: "end", truncated: true)
  end

  it "matches the identifier as part of the title" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [node("ENG-7"), node("ENG-8")], next_cursor: nil))

    result = described_class.call(company: company, user: member, q: "eng-7")

    expect(result.items.map { |item| item[:external_id] }).to eq(["lin-ENG-7"])
  end

  it "lists its parameters" do
    expect(described_class.parameters[:team_key]).to include(type: "string")
    expect(described_class.parameters[:since_days]).to include(maximum: Connectors::Services::LookBack::MAX_SINCE_DAYS)
  end

  it "raises when linear is not connected" do
    expect { described_class.call(company: company, user: admin) }.to raise_error(Search::NotConnected, /Linear/)
  end
end
