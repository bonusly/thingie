require "rails_helper"

RSpec.describe Points::Queries::LedgerHistory do
  include_context "with a company and members"

  it "returns recent weeks newest first" do
    old = create(:points_ledger_entry, company: company, user: member, week_key: "2020-W01")
    last_week = create(:points_ledger_entry, :last_week, company: company, user: member, created_at: 8.days.ago)
    this_week = create(:points_ledger_entry, company: company, user: member)

    entries = described_class.call(user: member, company: company, weeks: 2).to_a
    expect(entries).to eq([this_week, last_week])
    expect(entries).not_to include(old)
  end

  it "limits the number of entries" do
    3.times { create(:points_ledger_entry, company: company, user: member) }
    expect(described_class.call(user: member, company: company, limit: 2).count).to eq(2)
  end

  it "does not leak other users' entries" do
    create(:points_ledger_entry, company: company, user: admin)
    expect(described_class.call(user: member, company: company).count).to eq(0)
  end
end
