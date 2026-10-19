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

  it "does nothing for an archived, deleted or missing list" do
    draft
    list.archive!
    described_class.new.perform(list.id.to_s, admin.id.to_s)
    list.restore!
    list.update!(deleted_at: Time.current)
    described_class.new.perform(list.id.to_s, admin.id.to_s)
    described_class.new.perform(BSON::ObjectId.new.to_s, admin.id.to_s)
    expect(list.tasks.count).to eq(0)
    expect(draft.reload).to be_ready
  end

  it "keeps going when one draft cannot be sent and tells its author" do
    broken = create(:draft_task, :ready, company: company, list: list, author: member)
    broken.set(title: "")

    described_class.new.perform(list.id.to_s, admin.id.to_s)

    expect(draft.reload).to be_sent
    expect(broken.reload).to be_ready
    failure = Notification.for_recipient(member).where(kind: "draft_conversion_failed").first
    expect(failure.subject_id).to eq(broken.id)
    expect(failure.payload["name"]).to eq(list.name)
  end
end
