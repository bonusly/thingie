require "rails_helper"

RSpec.describe DraftTasks::Commands::Create do
  include_context "with a company and members"

  it "creates an unattached drafting draft with permitted attributes" do
    result = described_class.call(
      company: company, author: member,
      attrs: { title: "Plan offsite", points: 20, visibility: "private", scheduled_for: 1.day.from_now, state: "ready" }
    )

    expect(result).to be_success
    draft = result.value
    expect(draft).to be_drafting
    expect(draft.list).to be_nil
    expect(draft.points).to eq(20)
    expect(draft).to be_private
  end

  it "does not reserve points until the draft is attached and ready" do
    described_class.call(company: company, author: member, attrs: { title: "Later", points: 50 })
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "reports validation errors" do
    result = described_class.call(company: company, author: member, attrs: { title: "", points: 10 })
    expect(result).to be_failure
    expect(result.error.first).to match(/Title/)
  end
end
