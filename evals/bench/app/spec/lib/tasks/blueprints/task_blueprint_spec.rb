require "rails_helper"

RSpec.describe Tasks::Blueprints::TaskBlueprint do
  let(:task) { create(:task, due_on: Date.new(2026, 10, 10), assignee_ids: [BSON::ObjectId.new]) }

  it "renders ids as strings" do
    json = described_class.render_as_hash(task)
    expect(json[:id]).to eq(task.id.to_s)
    expect(json[:list_id]).to eq(task.list_id.to_s)
    expect(json[:assignee_ids]).to eq(task.assignee_ids.map(&:to_s))
  end

  it "computes overdue relative to the given day" do
    expect(described_class.render_as_hash(task, today: Date.new(2026, 10, 11))[:overdue]).to be(true)
    expect(described_class.render_as_hash(task, today: Date.new(2026, 10, 9))[:overdue]).to be(false)
  end

  it "adds counts and attachments in the detailed view" do
    create(:comment, company: task.company, commentable: task)
    create(:attachment, company: task.company, task: task)

    json = described_class.render_as_hash(task, view: :detailed)
    expect(json[:comment_count]).to eq(1)
    expect(json[:attachments].size).to eq(1)
  end
end
