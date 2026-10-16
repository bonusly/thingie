require "rails_helper"

RSpec.describe Admin::Queries::CompanyStats do
  include_context "with a company and members"

  it "summarizes the company" do
    list = create(:list, company: company, owner: admin)
    create(:task, company: company, list: list, author: admin)
    create(:task, :done, company: company, list: list, author: admin)
    create(:draft_task, :ready, company: company, list: list, author: member)
    create(:points_ledger_entry, company: company, user: member, amount: 12)
    create(:connector_account, company: company, user: member)

    stats = described_class.call(company: company)

    expect(stats).to have_attributes(members: 2, admins: 1, lists: 1, open_tasks: 1, done_tasks: 1, ready_drafts: 1,
                                     points_awarded_this_week: 12, connected_accounts: 1)
  end

  it "ignores last week's points" do
    create(:points_ledger_entry, :last_week, company: company, user: member, amount: 12)
    expect(described_class.call(company: company).points_awarded_this_week).to eq(0)
  end
end
