require "rails_helper"

RSpec.describe Connectors::Jobs::SyncAccountJob do
  include_context "with a github connector account"

  let(:issues) { Connectors::Github::Queries::ListIssues::Result.new(items: [], next_cursor: "7", pages_fetched: 1, since: 1.day.ago) }
  let(:pulls) { Connectors::Github::Queries::ListPullRequests::Result.new(items: [], next_cursor: nil, pages_fetched: 1, since: 1.day.ago) }

  it "runs every registered query and stores the last cursor" do
    allow(Connectors::Github::Queries::ListIssues).to receive(:call).and_return(issues)
    allow(Connectors::Github::Queries::ListPullRequests).to receive(:call).and_return(pulls)

    described_class.new.perform(account.id.to_s)

    expect(account.reload.last_synced_at).to be_within(5.seconds).of(Time.current)
    expect(account.cursor).to be_nil
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

  it "ignores paused accounts" do
    account.pause!
    allow(Connectors::Github::Queries::ListIssues).to receive(:call)
    described_class.new.perform(account.id.to_s)
    expect(Connectors::Github::Queries::ListIssues).not_to have_received(:call)
  end
end
