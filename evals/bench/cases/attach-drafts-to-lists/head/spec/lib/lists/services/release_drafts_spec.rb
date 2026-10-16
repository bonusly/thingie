require "rails_helper"

RSpec.describe Lists::Services::ReleaseDrafts do
  include_context "with a list and a ready draft"

  it "sweeps attached drafts back to drafting with no list" do
    draft
    drafting = create(:draft_task, company: company, list: list, author: admin, attached_at: 1.hour.ago)
    sent = create(:draft_task, :sent, company: company, list: list, author: member)

    expect(described_class.for_card(list.id)).to eq(2)

    expect(draft.reload).to be_drafting
    expect(draft.list_id).to be_nil
    expect(draft.ready_at).to be_nil
    expect(drafting.reload.list_id).to be_nil
    expect(sent.reload.list_id).to eq(list.id)
  end

  it "leaves drafts on other lists alone" do
    other = create(:draft_task, :ready, :attached, company: company, author: member)
    described_class.for_card(list.id)
    expect(other.reload).to be_ready
  end

  it "returns zero for a list that no longer exists" do
    expect(described_class.for_card(BSON::ObjectId.new)).to eq(0)
  end
end
