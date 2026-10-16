require "rails_helper"

RSpec.describe Points::Queries::GivingBalance do
  include_context "with a company and members"

  let(:now) { Time.utc(2026, 10, 14, 12) }

  def balance(user = member)
    described_class.call(user: user, company: company, now: now)
  end

  it "starts at the full membership budget" do
    expect(balance).to have_attributes(budget: 100, spent: 0, reserved: 0, remaining: 100, week_key: "2026-W42")
    expect(balance).not_to be_escrowed
  end

  it "subtracts points awarded this week, net of refunds" do
    create(:points_ledger_entry, company: company, user: member, amount: 30, week_key: "2026-W42")
    create(:points_ledger_entry, :refund, company: company, user: member, amount: 5, week_key: "2026-W42")
    create(:points_ledger_entry, company: company, user: member, amount: 50, week_key: "2026-W41")

    expect(balance.spent).to eq(25)
    expect(balance.remaining).to eq(75)
  end

  it "subtracts reservations held by ready drafts only" do
    create(:draft_task, :ready, company: company, author: member, points: 20)
    create(:draft_task, company: company, author: member, points: 40)
    create(:draft_task, :sent, company: company, author: member, points: 15)
    create(:draft_task, :ready, company: company, author: admin, points: 10)

    expect(balance.reserved).to eq(20)
    expect(balance.remaining).to eq(80)
    expect(balance).to be_escrowed
  end

  it "holds escrow for the author's ready drafts and nobody else's" do
    create(:draft_task, :ready, company: company, author: member, points: 20)
    create(:draft_task, company: company, author: member, points: 40)
    create(:draft_task, :sent, company: company, author: member, points: 15)
    create(:draft_task, :ready, company: company, author: admin, points: 10)

    expect(balance.reserved).to eq(20)
    expect(balance.remaining).to eq(80)
  end

  it "counts settled escrow as spent, not reserved" do
    draft = create(:draft_task, :sent, company: company, author: member, points: 15)
    create(:points_ledger_entry, :escrow, company: company, user: member, amount: 15, draft_task_id: draft.id, week_key: "2026-W42")

    expect(balance).to have_attributes(spent: 15, reserved: 0, remaining: 85)
  end

  it "never reports a negative remainder" do
    create(:points_ledger_entry, company: company, user: member, amount: 90, week_key: "2026-W42")
    create(:draft_task, :ready, company: company, author: member, points: 30)
    expect(balance.remaining).to eq(0)
    expect(balance.covers?(1)).to be(false)
  end

  it "honours a membership budget override" do
    member_membership.update!(points_budget_override: 25)
    expect(balance.budget).to eq(25)
  end

  it "raises for non-members" do
    expect { balance(outsider) }.to raise_error(Points::NotAMember)
  end
end
