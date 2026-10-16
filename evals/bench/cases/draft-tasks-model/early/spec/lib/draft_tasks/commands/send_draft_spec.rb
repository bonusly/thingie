require "rails_helper"

RSpec.describe DraftTasks::Commands::SendDraft do
  include_context "with a list and a ready draft"

  it "creates the task, settles the escrow and marks the draft sent" do
    result = described_class.call(draft: draft, actor: admin)

    expect(result).to be_success
    task = result.value
    expect(task.title).to eq(draft.title)
    expect(task.points).to eq(10)
    expect(draft.reload).to be_sent
    expect(draft.sent_task_id).to eq(task.id)
  end

  it "writes one ledger entry for the draft and frees the reservation" do
    task = described_class.call(draft: draft, actor: admin).value

    entry = PointsLedgerEntry.for_draft(draft).first
    expect(entry).to have_attributes(amount: 10, kind: "award", task_id: task.id, user_id: member.id)
    balance = Points::Queries::GivingBalance.call(user: member, company: company)
    expect(balance.spent).to eq(10)
    expect(balance.reserved).to eq(0)
  end

  it "skips the ledger for a draft with no points" do
    free = create(:draft_task, :ready, company: company, list: list, author: member, points: 0)
    described_class.call(draft: free, actor: member)
    expect(PointsLedgerEntry.for_draft(free)).not_to exist
    expect(free.reload).to be_sent
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
    expect(PointsLedgerEntry.for_draft(draft)).not_to exist
  end
end
