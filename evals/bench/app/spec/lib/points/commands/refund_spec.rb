require "rails_helper"

RSpec.describe Points::Commands::Refund do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: member) }
  let(:award) { create(:points_ledger_entry, company: company, user: member, task: task, amount: 15) }

  it "writes a matching refund entry" do
    result = described_class.call(entry: award, note: "task cancelled")

    expect(result).to be_success
    expect(result.value).to have_attributes(kind: "refund", amount: 15, week_key: award.week_key, note: "task cancelled")
    expect(Points::Queries::GivingBalance.call(user: member, company: company).spent).to eq(0)
  end

  it "refunds the same award only once" do
    described_class.call(entry: award)
    expect(described_class.call(entry: award)).to be_failure
  end

  it "only refunds awards" do
    reset = create(:points_ledger_entry, :reset, company: company, user: member)
    expect(described_class.call(entry: reset).error).to match(/only awards/)
  end
end
