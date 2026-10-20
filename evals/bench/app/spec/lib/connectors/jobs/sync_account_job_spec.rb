require "rails_helper"

RSpec.describe Connectors::Jobs::SyncAccountJob do
  include_context "with a github connector account"

  def result_for(klass, items: [], next_cursor: nil, pages: 1)
    klass::Result.new(items: items, next_cursor: next_cursor, pages_fetched: pages, since: 1.day.ago)
  end

  def issue(id)
    { external_id: id.to_s, kind: "issue", title: "Issue #{id}", url: "https://github.com/acme/app/issues/#{id}", external_updated_at: 1.hour.ago, payload: {} }
  end

  before do
    allow(Connectors::Github::Queries::ListIssues).to receive(:call).and_return(result_for(Connectors::Github::Queries::ListIssues, items: [issue(1)]))
    allow(Connectors::Github::Queries::ListPullRequests).to receive(:call).and_return(result_for(Connectors::Github::Queries::ListPullRequests))
  end

  it "runs every registered query over the window and advances last_synced_at" do
    travel_to(Time.zone.parse("2026-10-16 09:00:00")) { described_class.new.perform(account.id.to_s) }

    expected_since = Date.new(2026, 10, 2).in_time_zone
    expect(Connectors::Github::Queries::ListIssues).to have_received(:call).with(account_id: account.id.to_s, since: expected_since)
    expect(Connectors::Github::Queries::ListPullRequests).to have_received(:call).with(account_id: account.id.to_s, since: expected_since)
    expect(account.reload.last_synced_at).to eq(Time.zone.parse("2026-10-16 09:00:00"))
    expect(account.external_items.pluck(:external_id)).to eq(["1"])
  end

  it "uses the configured channels as scopes for slack" do
    slack = create(:connector_account, :slack, :with_channels, company: company, user: member)
    allow(Connectors::Slack::Queries::ListMessages).to receive(:call).and_return(result_for(Connectors::Slack::Queries::ListMessages))

    described_class.new.perform(slack.id.to_s)

    expect(Connectors::Slack::Queries::ListMessages).to have_received(:call).with(hash_including(channel: "C123"))
    expect(Connectors::Slack::Queries::ListMessages).to have_received(:call).with(hash_including(channel: "C456"))
  end

  it "pauses the account when the token is rejected" do
    allow(Connectors::Github::Queries::ListIssues).to receive(:call).and_raise(Connectors::Unauthorized.new("github"))

    described_class.new.perform(account.id.to_s)

    expect(account.reload).to be_paused
    expect(account.last_error).to match(/rejected/)
  end

  it "reschedules itself when rate limited" do
    allow(Connectors::Github::Queries::ListIssues).to receive(:call).and_raise(Connectors::RateLimited.new("github", retry_after: 120))

    expect { described_class.new.perform(account.id.to_s) }.to change(described_class.jobs, :size).by(1)
    expect(described_class.jobs.last["at"]).to be_within(5).of(120.seconds.from_now.to_f)
  end

  it "records and re-raises other failures so Sidekiq retries" do
    allow(Connectors::Github::Queries::ListIssues).to receive(:call).and_raise(Faraday::ConnectionFailed, "boom")

    expect { described_class.new.perform(account.id.to_s) }.to raise_error(Faraday::ConnectionFailed)
    expect(account.reload.last_error).to eq("boom")
    expect(account.last_synced_at).to be_within(1.second).of(2.days.ago)
  end

  it "ignores paused accounts" do
    account.pause!
    described_class.new.perform(account.id.to_s)
    expect(Connectors::Github::Queries::ListIssues).not_to have_received(:call)
  end
end
