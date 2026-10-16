require "rails_helper"

RSpec.describe DraftTasks::Commands::Create do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  it "creates a drafting draft with permitted attributes" do
    result = described_class.call(
      company: company, author: member, list: list,
      attrs: { title: "Plan offsite", points: 20, visibility: "private", scheduled_for: 1.day.from_now, state: "ready" }
    )

    expect(result).to be_success
    draft = result.value
    expect(draft).to be_drafting
    expect(draft.points).to eq(20)
    expect(draft).to be_private
  end

  it "does not reserve points until the draft is ready" do
    described_class.call(company: company, author: member, list: list, attrs: { title: "Later", points: 50 })
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "rejects points above the author's weekly budget" do
    member_membership.update!(points_budget_override: 30)

    result = described_class.call(company: company, author: member, list: list, attrs: { title: "Big", points: 40 })

    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/weekly budget of 30/))
  end

  it "allows points the author has already spent, since nothing is held until ready" do
    create(:points_ledger_entry, company: company, user: member, amount: 90)

    result = described_class.call(company: company, author: member, list: list, attrs: { title: "Next", points: 40 })

    expect(result).to be_success
  end

  it "rejects an author who is not a member" do
    result = described_class.call(company: company, author: outsider, list: list, attrs: { title: "x", points: 5 })
    expect(result.error).to be_a(Points::NotAMember)
  end

  it "rejects an archived list" do
    list.archive!
    result = described_class.call(company: company, author: member, list: list, attrs: { title: "x" })
    expect(result).to be_failure
    expect(result.error).to match(/archived/)
  end

  it "rejects a list from another company" do
    result = described_class.call(company: company, author: member, list: create(:list), attrs: { title: "x" })
    expect(result).to be_failure
  end
end
