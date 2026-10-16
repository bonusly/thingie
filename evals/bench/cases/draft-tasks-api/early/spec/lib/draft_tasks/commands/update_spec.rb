require "rails_helper"

RSpec.describe DraftTasks::Commands::Update do
  include_context "with a company and members"

  let(:draft) { create(:draft_task, company: company, author: member, title: "Before") }

  it "updates a drafting draft and records who edited it" do
    result = described_class.call(draft: draft, actor: member, attrs: { title: "After", note: "see thread" })
    expect(result).to be_success
    expect(draft.reload.title).to eq("After")
    expect(draft.note).to eq("see thread")
    expect(draft.revision).to eq(2)
    expect(draft.last_edited_by_id).to eq(member.id)
  end

  it "ignores keys the client may not set" do
    result = described_class.call(draft: draft, actor: member, attrs: { title: "After", state: "sent" })
    expect(result).to be_success
    expect(draft.reload).to be_drafting
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

  it "surfaces validation errors without writing" do
    result = described_class.call(draft: draft, actor: member, attrs: { points: Task::MAX_POINTS + 1 })
    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/Points/))
    expect(draft.reload.revision).to eq(1)
  end
end
