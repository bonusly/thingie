require "rails_helper"

RSpec.describe Search::Tools::SlackSearch do
  include_context "with a slack connector account"

  def message(ts, text: "hello")
    { "ts" => ts, "text" => text, "user" => "U1" }
  end

  it "defaults to the first configured channel" do
    allow(client).to receive(:messages).and_return(Connectors::Page.new(items: [message("1700000000.000100")], next_cursor: nil))

    result = described_class.call(company: company, user: member)

    expect(client).to have_received(:messages).with(hash_including(channel: "C123"))
    expect(result.items.first[:external_id]).to eq("C123:1700000000.000100")
  end

  it "searches an explicit channel and matches on text" do
    allow(client).to receive(:messages).and_return(
      Connectors::Page.new(items: [message("1.0", text: "deploy done"), message("2.0", text: "lunch?")], next_cursor: "abc")
    )

    result = described_class.call(company: company, user: member, channel: "C456", q: "deploy")

    expect(client).to have_received(:messages).with(hash_including(channel: "C456"))
    expect(result.items.map { |item| item[:title] }).to eq(["deploy done"])
    expect(result).to have_attributes(next_cursor: "abc", truncated: true)
  end

  it "fails clearly when no channel is configured" do
    bare = create(:connector_account, :slack, company: company, user: admin)
    allow(Connectors::Slack::Client).to receive(:new).with(bare).and_return(client)

    expect { described_class.call(company: company, user: admin) }.to raise_error(Connectors::InvalidInput, /channel/)
  end

  it "raises when slack is not connected" do
    expect { described_class.call(company: company, user: outsider) }.to raise_error(Search::NotConnected)
  end
end
