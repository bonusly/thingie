RSpec.shared_context "with a company and members" do
  let(:company) { create(:company) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:outsider) { create(:user) }
  let!(:admin_membership) { create(:membership, :admin, company: company, user: admin) }
  let!(:member_membership) { create(:membership, company: company, user: member) }
end

RSpec.shared_context "with a list and a ready draft" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }
  let(:draft) { create(:draft_task, :ready, company: company, list: list, author: member, points: 10, note: "ship it") }
end

RSpec.shared_context "with a github connector account" do
  include_context "with a company and members"

  let(:account) { create(:connector_account, company: company, user: member, last_synced_at: 2.days.ago) }
  let(:client) { instance_double(Connectors::Github::Client) }

  before { allow(Connectors::Github::Client).to receive(:new).with(account).and_return(client) }
end

RSpec.shared_context "with a slack connector account" do
  include_context "with a company and members"

  let(:account) { create(:connector_account, :slack, :with_channels, company: company, user: member) }
  let(:client) { instance_double(Connectors::Slack::Client) }

  before do
    allow(Connectors::Slack::Client).to receive(:new).with(account).and_return(client)
    allow(client).to receive(:permalink) { |channel:, ts:| "https://slack.test/#{channel}/#{ts}" }
    allow(client).to receive(:replies).and_return([])
  end
end

RSpec.shared_context "with a linear connector account" do
  include_context "with a company and members"

  let(:account) { create(:connector_account, :linear, company: company, user: member, last_synced_at: 1.day.ago) }
  let(:client) { instance_double(Connectors::Linear::Client) }

  before { allow(Connectors::Linear::Client).to receive(:new).with(account).and_return(client) }
end
