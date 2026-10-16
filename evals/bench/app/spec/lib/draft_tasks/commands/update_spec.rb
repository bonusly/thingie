require "rails_helper"

RSpec.describe DraftTasks::Commands::Update do
  include_context "with a company and members"

  let(:draft) { create(:draft_task, company: company, author: member, title: "Before") }

  it "updates a drafting draft" do
    result = described_class.call(draft: draft, actor: member, attrs: { title: "After", note: "see thread" })
    expect(result).to be_success
    expect(draft.reload.title).to eq("After")
    expect(draft.note).to eq("see thread")
  end

  it "refuses when the draft is ready" do
    draft.mark_ready!
    result = described_class.call(draft: draft, actor: member, attrs: { title: "After" })
    expect(result).to be_failure
    expect(result.error).to be_a(DraftTasks::NotEditable)
  end

  it "refuses non-authors" do
    result = described_class.call(draft: draft, actor: admin, attrs: { title: "After" })
    expect(result).to be_failure
    expect(draft.reload.title).to eq("Before")
  end

  it "surfaces validation errors" do
    result = described_class.call(draft: draft, actor: member, attrs: { points: Task::MAX_POINTS + 1 })
    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/Points/))
  end
end
