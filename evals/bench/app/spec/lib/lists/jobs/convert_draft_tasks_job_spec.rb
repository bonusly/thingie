require "rails_helper"

RSpec.describe Lists::Jobs::ConvertDraftTasksJob do
  include_context "with a list and a ready draft"

  it "converts every ready draft on the list" do
    second = create(:draft_task, :ready, company: company, list: list, author: admin, points: 5)
    drafting = create(:draft_task, company: company, list: list, author: member)

    described_class.new.perform(list.id.to_s, admin.id.to_s)

    expect(draft.reload).to be_sent
    expect(second.reload).to be_sent
    expect(drafting.reload).to be_drafting
    expect(list.tasks.count).to eq(2)
  end

  it "does nothing for an archived or missing list" do
    list.archive!
    described_class.new.perform(list.id.to_s, admin.id.to_s)
    described_class.new.perform(BSON::ObjectId.new.to_s, admin.id.to_s)
    expect(list.tasks.count).to eq(0)
  end

  it "keeps going when one draft cannot be sent" do
    broken = create(:draft_task, :ready, company: company, list: list, author: member)
    broken.set(title: "")

    described_class.new.perform(list.id.to_s, admin.id.to_s)

    expect(draft.reload).to be_sent
    expect(broken.reload).to be_ready
  end
end
