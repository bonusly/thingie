require "rails_helper"

RSpec.describe DraftTasks::Blueprints::CommentBlueprint do
  let(:draft) { create(:draft_task, :sent, title: "Tag release") }

  it "links a draft comment back to its draft" do
    comment = create(:comment, draft_task_id: draft.id)
    json = described_class.render_as_hash(comment)

    expect(json[:from_draft]).to be(true)
    expect(json[:draft]).to eq(id: draft.id.to_s, title: "Tag release", author_id: draft.author_id.to_s)
  end

  it "leaves the draft blank for ordinary comments" do
    json = described_class.render_as_hash(create(:comment))
    expect(json[:from_draft]).to be(false)
    expect(json[:draft]).to be_nil
  end
end
