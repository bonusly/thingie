require "rails_helper"

RSpec.describe DraftTasks::Commands::SendDraft do
  include_context "with a list and a ready draft"

  it "creates the task, spends the points and marks the draft sent" do
    result = described_class.call(draft: draft, actor: admin)

    expect(result).to be_success
    task = result.value
    expect(task.title).to eq(draft.title)
    expect(task.points).to eq(10)
    expect(task.draft_task_id).to eq(draft.id)
    expect(draft.reload).to be_sent
    expect(draft.sent_task_id).to eq(task.id)

    balance = Points::Queries::GivingBalance.call(user: member, company: company)
    expect(balance.spent).to eq(10)
    expect(balance.reserved).to eq(0)
  end

  it "moves the recording onto the task" do
    recorded = create(:draft_task, :ready, :with_recording, company: company, list: list, author: member)
    task = described_class.call(draft: recorded, actor: member).value
    expect(task.attachments.map(&:id)).to eq([recorded.attachment_id])
    expect(recorded.attachment.draft_task_id).to be_nil
  end

  it "leaves the draft ready for the caller to finish when asked" do
    result = described_class.call(draft: draft, actor: admin, finalize: false)
    expect(result).to be_success
    expect(draft.reload).to be_ready
    expect(Notification.where(kind: "draft_sent").count).to eq(0)
  end

  it "notifies the author when someone else sends it" do
    described_class.call(draft: draft, actor: admin)
    expect(Notification.for_recipient(member).where(kind: "draft_sent").count).to eq(1)
  end

  it "stays quiet when the author sends it or the job does" do
    described_class.call(draft: draft, actor: nil)
    expect(Notification.where(kind: "draft_sent").count).to eq(0)
  end

  it "fails when the draft is still drafting" do
    drafting = create(:draft_task, company: company, list: list, author: member)
    result = described_class.call(draft: drafting, actor: member)
    expect(result.error).to be_a(DraftTasks::WrongState)
  end

  it "leaves the draft ready when task creation fails" do
    draft.set(title: "")
    result = described_class.call(draft: draft, actor: member)
    expect(result).to be_failure
    expect(draft.reload).to be_ready
  end
end
