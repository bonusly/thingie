require "rails_helper"

RSpec.describe DraftTasks::Queries::ListDraftComments do
  include_context "with a list and a ready draft"

  it "returns nothing for an unsent draft" do
    expect(described_class.call(draft: draft).to_a).to eq([])
  end

  it "lists the sent task's comments oldest first" do
    task = create(:task, company: company, list: list, author: member)
    draft.mark_sent!(task)
    later = create(:comment, company: company, commentable: task, created_at: 1.minute.ago)
    earlier = create(:comment, company: company, commentable: task, created_at: 1.hour.ago)
    create(:comment, company: company)

    expect(described_class.call(draft: draft).to_a).to eq([earlier, later])
  end

  it "caps the list" do
    task = create(:task, company: company, list: list, author: member)
    draft.mark_sent!(task)
    create_list(:comment, described_class::LIMIT + 1, company: company, commentable: task)

    expect(described_class.call(draft: draft).count(true)).to eq(described_class::LIMIT)
  end
end
