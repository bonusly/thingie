require "rails_helper"

RSpec.describe Tasks::Commands::Create do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  def call(attrs)
    described_class.call(company: company, author: admin, list: list, attrs: attrs)
  end

  it "creates the task and a created event" do
    result = call(title: "Write release notes", due_on: Date.new(2026, 11, 1))

    expect(result).to be_success
    task = result.value
    expect(task.list).to eq(list)
    expect(task.author).to eq(admin)
    expect(task.events.of_kind("created").count).to eq(1)
  end

  it "awards points from the author's weekly budget" do
    result = call(title: "Tag the build", points: 15)

    expect(result).to be_success
    balance = Points::Queries::GivingBalance.call(user: admin, company: company)
    expect(balance.spent).to eq(15)
  end

  it "fails before saving when the author cannot cover the points" do
    create(:membership, company: company, user: outsider, points_budget_override: 5)
    list.add_member(outsider)

    result = described_class.call(company: company, author: outsider, list: list, attrs: { title: "Big", points: 10 })

    expect(result).to be_failure
    expect(result.error).to be_a(Points::InsufficientBalance)
    expect(Task.count).to eq(0)
  end

  it "notifies assignees other than the author" do
    call(title: "Review", assignee_ids: [member.id, admin.id])

    expect(Notification.for_recipient(member).where(kind: "task_assigned").count).to eq(1)
    expect(Notification.for_recipient(admin).count).to eq(0)
  end

  it "rejects a list from another company" do
    result = described_class.call(company: company, author: admin, list: create(:list), attrs: { title: "x" })
    expect(result).to be_failure
    expect(result.error).to be_a(Tasks::WrongCompany)
  end

  it "returns validation messages" do
    result = call(title: "")
    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/Title/))
  end
end
