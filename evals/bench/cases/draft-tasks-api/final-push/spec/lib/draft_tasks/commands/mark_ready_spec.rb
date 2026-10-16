require "rails_helper"

RSpec.describe DraftTasks::Commands::MarkReady do
  include_context "with a company and members"

  let(:draft) { create(:draft_task, company: company, author: member, points: 30) }

  it "moves the draft to ready and reserves its points" do
    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_ready
    expect(draft.points_reserved_at).to be_present
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(30)
  end

  it "applies a final note and schedule" do
    at = 2.hours.from_now.change(usec: 0)
    result = described_class.call(draft: draft, actor: member, edits: { note: "final", scheduled_for: at })

    expect(result).to be_success
    expect(draft.reload.note).to eq("final")
    expect(draft.scheduled_for).to eq(at)
  end

  it "only takes the note and schedule as final edits" do
    described_class.call(draft: draft, actor: member, edits: { title: "Renamed", author_id: admin.id })
    expect(draft.reload.title).not_to eq("Renamed")
    expect(draft.author_id).to eq(member.id)
  end

  it "fails when the remaining budget cannot cover the points" do
    create(:draft_task, :ready, company: company, author: member, points: 80)

    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_failure
    expect(result.error).to be_a(Points::InsufficientBalance)
    expect(draft.reload).to be_drafting
  end

  it "fails when the draft is not drafting" do
    draft.mark_ready!
    result = described_class.call(draft: draft, actor: member)
    expect(result.error).to be_a(DraftTasks::WrongState)
  end

  it "fails for a non-author" do
    result = described_class.call(draft: draft, actor: admin)
    expect(result).to be_failure
    expect(result.error).to match(/author/)
  end

  it "reports a busy lock instead of raising" do
    lock = RedisLock.new("locks:draft_task:#{draft.id}", ttl: 5)
    lock.acquire

    result = described_class.call(draft: draft, actor: member)

    expect(result.error).to be_a(DraftTasks::Commands::SendDraft::Lock::Busy)
    lock.release
  end
end
