require "rails_helper"

RSpec.describe Connectors::Slack::Queries::ListMessages do
  include_context "with a company and members"

  let(:account) { create(:connector_account, :slack, company: company, user: member) }
  let(:client) { instance_double(Connectors::Slack::Client) }

  before do
    allow(Connectors::Slack::Client).to receive(:new).with(account).and_return(client)
    allow(client).to receive(:permalink) { |channel:, ts:| "https://slack.test/#{channel}/#{ts}" }
  end

  def message(ts, text: "hello", subtype: nil)
    { "ts" => ts, "text" => text, "user" => "U1", "subtype" => subtype }.compact
  end

  it "requires a channel" do
    expect { described_class.call(account_id: account.id.to_s) }.to raise_error(Connectors::InvalidInput)
  end

  it "normalizes messages and skips system subtypes" do
    allow(client).to receive(:messages).and_return(
      Connectors::Page.new(items: [message("1700000000.000100"), message("1700000000.000200", subtype: "channel_join")], next_cursor: nil)
    )

    result = described_class.call(account_id: account.id.to_s, channel: "C123")

    expect(result.items.size).to eq(1)
    expect(result.items.first).to include(external_id: "C123:1700000000.000100", kind: "message", url: "https://slack.test/C123/1700000000.000100")
    expect(result.items.first[:external_updated_at]).to eq(Time.zone.at(1_700_000_000.0001))
  end

  it "pages with Slack cursors up to the limit" do
    allow(client).to receive(:messages) { |cursor:, **| Connectors::Page.new(items: [message("#{cursor.to_i + 1}.0")], next_cursor: (cursor.to_i + 1).to_s) }

    result = described_class.call(account_id: account.id.to_s, channel: "C123", limit: 50)

    expect(result.pages_fetched).to eq(5)
    expect(result.next_cursor).to eq("5")
    expect(client).to have_received(:messages).with(hash_including(limit: 50)).exactly(5).times
  end
end
