require "rails_helper"

RSpec.describe Tasks::Queries::ListTasks do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }
  let(:private_list) { create(:list, :private, company: company, owner: admin) }

  let!(:open_task) { create(:task, company: company, list: list, title: "Write docs", position: 2) }
  let!(:done_task) { create(:task, :done, company: company, list: list, title: "Ship it", position: 1) }
  let!(:hidden_task) { create(:task, company: company, list: private_list) }

  def call(filters = {})
    described_class.call(company: company, user: member, filters: filters).to_a
  end

  it "only returns tasks in lists the user can see, in position order" do
    expect(call).to eq([done_task, open_task])
    expect(call).not_to include(hidden_task)
  end

  it "filters by state" do
    expect(call(state: "done")).to eq([done_task])
  end

  it "filters by title substring" do
    expect(call(q: "docs")).to eq([open_task])
  end

  it "filters by due date window" do
    due = create(:task, company: company, list: list, due_on: Date.new(2026, 10, 20))
    expect(call(due_before: Date.new(2026, 10, 21), due_after: Date.new(2026, 10, 19))).to eq([due])
  end

  it "ignores filters it does not know" do
    expect(call(company_id: BSON::ObjectId.new, points: 99)).to eq([done_task, open_task])
  end
end
