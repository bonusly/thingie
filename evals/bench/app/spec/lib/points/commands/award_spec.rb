require "rails_helper"

RSpec.describe Points::Commands::Award do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: member) }

  it "writes an award entry for the current week and a task event" do
    result = described_class.call(company: company, user: member, task: task, amount: 25)

    expect(result).to be_success
    entry = result.value
    expect(entry).to have_attributes(kind: "award", amount: 25, task: task)
    expect(entry.week_key).to eq(Points::Queries::WeeklyWindow.call(company: company).key)
    expect(task.events.of_kind("points_awarded").first.data["amount"]).to eq(25)
  end

  it "fails when the balance cannot cover the amount" do
    create(:draft_task, :ready, company: company, author: member, points: 90)

    result = described_class.call(company: company, user: member, task: task, amount: 20)

    expect(result).to be_failure
    expect(result.error).to be_a(Points::InsufficientBalance)
    expect(result.error.remaining).to eq(10)
  end

  it "rejects non-positive amounts" do
    expect(described_class.call(company: company, user: member, task: task, amount: 0)).to be_failure
  end

  it "fails cleanly for non-members" do
    result = described_class.call(company: company, user: outsider, task: task, amount: 5)
    expect(result.error).to be_a(Points::NotAMember)
  end
end
