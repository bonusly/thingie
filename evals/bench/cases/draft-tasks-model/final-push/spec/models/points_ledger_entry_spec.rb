require "rails_helper"

RSpec.describe PointsLedgerEntry do
  it "rejects a zero amount" do
    expect(build(:points_ledger_entry, amount: 0)).not_to be_valid
  end

  it "requires an ISO week key" do
    expect(build(:points_ledger_entry, week_key: "2026-42")).not_to be_valid
    expect(build(:points_ledger_entry, week_key: "2026-W42")).to be_valid
  end

  describe "#signed_amount" do
    it "is negative for awards and positive otherwise" do
      expect(build(:points_ledger_entry, amount: 10).signed_amount).to eq(-10)
      expect(build(:points_ledger_entry, :refund, amount: 10).signed_amount).to eq(10)
    end
  end

  describe "#from_draft?" do
    it "is true only when the entry settled a draft" do
      expect(build(:points_ledger_entry, :escrow)).to be_from_draft
      expect(build(:points_ledger_entry)).not_to be_from_draft
    end
  end

  describe "scopes" do
    let(:company) { create(:company) }
    let(:user) { create(:user) }

    it "separate awards and refunds for a week" do
      award = create(:points_ledger_entry, company: company, user: user)
      refund = create(:points_ledger_entry, :refund, company: company, user: user)
      create(:points_ledger_entry, :last_week, company: company, user: user)

      this_week = described_class.for_user(user).for_week(award.week_key)
      expect(this_week.awards.to_a).to eq([award])
      expect(this_week.refunds.to_a).to eq([refund])
    end

    it "finds the entry that settled a draft" do
      draft = create(:draft_task, company: company)
      entry = create(:points_ledger_entry, :escrow, company: company, user: user, draft_task_id: draft.id)
      create(:points_ledger_entry, :escrow, company: company, user: user)

      expect(described_class.for_draft(draft).to_a).to eq([entry])
    end
  end
end
