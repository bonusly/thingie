require "rails_helper"

RSpec.describe DraftTasks::Blueprints::DraftTaskBlueprint do
  it "renders a drafting draft as editable with no reservation" do
    draft = create(:draft_task, points: 12)
    json = described_class.render_as_hash(draft)

    expect(json).to include(id: draft.id.to_s, state: "drafting", editable: true, reserved_points: 0)
    expect(json[:sent_task_id]).to be_nil
  end

  it "renders a sent draft with its task id" do
    draft = create(:draft_task, :sent, points: 12, sent_task_id: BSON::ObjectId.new)
    json = described_class.render_as_hash(draft)

    expect(json[:sent_task_id]).to eq(draft.sent_task_id.to_s)
    expect(json[:editable]).to be(false)
  end

  it "stringifies assignee and label ids" do
    draft = build(:draft_task, assignee_ids: [BSON::ObjectId.new], label_ids: [BSON::ObjectId.new])
    json = described_class.render_as_hash(draft)
    expect(json[:assignee_ids].first).to be_a(String)
    expect(json[:label_ids].first).to be_a(String)
  end
end
