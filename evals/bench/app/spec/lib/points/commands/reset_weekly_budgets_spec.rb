require "rails_helper"

RSpec.describe Points::Commands::ResetWeeklyBudgets do
  include_context "with a company and members"

  let(:now) { Time.utc(2026, 10, 14, 12) }

  it "writes one reset entry per active member" do
    create(:membership, :removed, company: company)
    create(:membership, company: company, points_budget_override: 0)

    result = described_class.call(company: company, now: now)

    expect(result.value).to eq(reset: 2, week_key: "2026-W42")
    expect(PointsLedgerEntry.for_company(company).where(kind: "reset").count).to eq(2)
  end

  it "is idempotent within a week" do
    described_class.call(company: company, now: now)
    result = described_class.call(company: company, now: now + 1.day)
    expect(result.value[:reset]).to eq(0)
    expect(PointsLedgerEntry.for_company(company).count).to eq(2)
  end

  it "writes again for a new week" do
    described_class.call(company: company, now: now)
    described_class.call(company: company, now: now + 7.days)
    expect(PointsLedgerEntry.for_company(company).count).to eq(4)
  end
end
