require "rails_helper"

RSpec.describe DraftTasks::Queries::ListDrafts do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }
  let!(:soon) { create(:draft_task, company: company, list: list, author: member, scheduled_for: 1.hour.from_now) }
  let!(:later) { create(:draft_task, :ready, company: company, list: list, author: member, scheduled_for: 2.days.from_now) }
  let!(:elsewhere) { create(:draft_task, company: company, author: member, scheduled_for: 3.days.from_now) }

  before { create(:draft_task, company: company, list: list, author: admin) }

  it "lists the author's drafts soonest first" do
    expect(described_class.call(company: company, author: member).to_a).to eq([soon, later, elsewhere])
  end

  it "filters by state and ignores unknown states" do
    expect(described_class.call(company: company, author: member, state: "ready").to_a).to eq([later])
    expect(described_class.call(company: company, author: member, state: "bogus").count).to eq(3)
  end

  it "filters by list" do
    expect(described_class.call(company: company, author: member, list_id: list.id).to_a).to eq([soon, later])
  end
end
