require "rails_helper"

RSpec.describe Search::Tools::GithubSearch do
  include_context "with a github connector account"

  def issue(id, title: "Issue #{id}")
    { "id" => id, "title" => title, "html_url" => "https://github.com/acme/app/issues/#{id}", "updated_at" => "2026-10-15T10:00:00Z", "number" => id, "state" => "open" }
  end

  it "describes itself for a model" do
    expect(described_class.provider).to eq("github")
    expect(described_class.description).to include("14 days")
    expect(described_class.parameters.keys).to include(:q, :since_days, :pages, :cursor, :kind)
  end

  it "filters issues by title and reports whether more pages remain" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [issue(1, title: "Flaky build"), issue(2, title: "Docs")], next_cursor: nil))

    result = described_class.call(company: company, user: member, q: "flaky")

    expect(result.items.map { |item| item[:external_id] }).to eq(["1"])
    expect(result).to have_attributes(provider: "github", truncated: false, next_cursor: nil)
    expect(result.to_h[:since]).to be_a(String)
  end

  it "passes cursor, pages and since_days through to the query" do
    allow(client).to receive(:issues).and_return(Connectors::Page.new(items: [issue(1)], next_cursor: 4))

    result = described_class.call(company: company, user: member, cursor: "3", pages: "1", since_days: "2")

    expect(client).to have_received(:issues).with(hash_including(cursor: "3")).once
    expect(result).to have_attributes(next_cursor: "4", truncated: true)
    expect(result.since).to be_within(5.seconds).of(2.days.ago)
  end

  it "searches pull requests when asked" do
    allow(client).to receive(:pull_requests).and_return(Connectors::Page.empty)
    described_class.call(company: company, user: member, kind: "pull_request")
    expect(client).to have_received(:pull_requests)
  end

  it "raises when the user has no connected github account" do
    expect { described_class.call(company: company, user: admin) }.to raise_error(Search::NotConnected, /GitHub is not connected/)
  end

  it "rejects a page budget above the cap" do
    expect { described_class.call(company: company, user: member, pages: 9) }.to raise_error(Search::PageLimitExceeded, /At most 5 pages/)
  end
end
