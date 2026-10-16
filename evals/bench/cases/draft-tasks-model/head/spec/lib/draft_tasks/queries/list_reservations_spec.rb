require "rails_helper"

RSpec.describe DraftTasks::Queries::ListReservations do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }
  let!(:older) { create(:draft_task, :ready, company: company, list: list, author: member, points: 5, ready_at: 2.hours.ago) }
  let!(:newer) { create(:draft_task, :ready, company: company, list: list, author: member, points: 8, ready_at: 1.hour.ago) }

  before do
    create(:draft_task, :ready, company: company, list: list, author: member, points: 0)
    create(:draft_task, company: company, list: list, author: member, points: 9)
    create(:draft_task, :ready, company: company, list: list, author: admin, points: 7)
  end

  it "lists the author's point-holding ready drafts, newest first" do
    expect(described_class.call(company: company, author: member).to_a).to eq([newer, older])
  end

  it "honours the limit" do
    expect(described_class.call(company: company, author: member, limit: 1).to_a).to eq([newer])
  end
end
