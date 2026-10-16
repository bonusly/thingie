require "rails_helper"

RSpec.describe Search::Queries::ConnectedSearch do
  include_context "with a company and members"

  def tool_result(provider, items: [], next_cursor: nil)
    Search::Tools::Base::Result.new(provider: provider, items: items, next_cursor: next_cursor, truncated: next_cursor.present?, since: 1.day.ago)
  end

  def item(id, at:)
    { external_id: id, kind: "issue", title: id, url: "https://example.test/#{id}", external_updated_at: at, payload: {} }
  end

  before do
    allow(Search::Tools::GithubSearch).to receive(:call).and_return(tool_result("github", items: [item("gh", at: 1.hour.ago)], next_cursor: "2"))
    allow(Search::Tools::SlackSearch).to receive(:call).and_return(tool_result("slack", items: [item("sl", at: 1.minute.ago)], next_cursor: "dXNlcjpV"))
    allow(Search::Tools::LinearSearch).to receive(:call).and_raise(Search::NotConnected.new("linear"))
  end

  it "merges results newest first, keyed by provider, and returns the cursor to continue from" do
    result = described_class.call(company: company, user: member, q: "x", cursor: "abc")

    expect(Search::Tools::GithubSearch).to have_received(:call).with(hash_including(cursor: "abc", q: "x"))
    expect(Search::Tools::SlackSearch).to have_received(:call).with(hash_including(cursor: "abc"))
    expect(result.items.map { |i| [i[:provider], i[:external_id]] }).to eq([%w[slack sl], %w[github gh]])
    expect(result.next_cursor).to eq("dXNlcjpV")
    expect(result).to have_attributes(truncated: true, skipped: ["linear"])
  end

  it "only runs the requested providers" do
    result = described_class.call(company: company, user: member, providers: ["github"], since_days: 3)

    expect(Search::Tools::GithubSearch).to have_received(:call).with(hash_including(since_days: 3, cursor: nil))
    expect(Search::Tools::SlackSearch).not_to have_received(:call)
    expect(result.skipped).to be_empty
  end

  it "rejects an unknown provider" do
    expect { described_class.call(company: company, user: member, providers: ["jira"]) }.to raise_error(Connectors::UnknownProvider)
  end
end
