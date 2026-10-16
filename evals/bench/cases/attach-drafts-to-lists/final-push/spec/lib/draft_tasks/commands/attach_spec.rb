require "rails_helper"

RSpec.describe DraftTasks::Commands::Attach do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id]) }
  let(:draft) { create(:draft_task, company: company, author: member, points: 30, title: "Plan offsite") }

  it "attaches a drafting draft, marks it ready and leaves an attach comment on the list" do
    result = described_class.call(draft: draft, list: list, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_ready
    expect(draft.list).to eq(list)
    expect(draft.attached_at).to be_present
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(30)

    comment = list.comments.from_drafts.first
    expect(comment.draft_task_id).to eq(draft.id)
    expect(comment.author).to eq(member)
    expect(comment.body).to eq("Attached a draft: Plan offsite")
  end

  it "moves a ready draft to another list along with its comment" do
    described_class.call(draft: draft, list: list, actor: member)
    other = create(:list, company: company, owner: admin)

    result = described_class.call(draft: draft, list: other, actor: member)

    expect(result).to be_success
    expect(draft.reload.list).to eq(other)
    expect(draft).to be_ready
    expect(list.comments.from_drafts.count).to eq(0)
    expect(other.comments.from_drafts.count).to eq(1)
  end

  it "is a no-op when already on that list" do
    described_class.call(draft: draft, list: list, actor: member)
    expect { described_class.call(draft: draft, list: list, actor: member) }
      .not_to change { list.comments.count }
  end

  it "fails when the remaining budget cannot cover the points" do
    create(:draft_task, :ready, company: company, list: list, author: member, points: 80)

    result = described_class.call(draft: draft, list: list, actor: member)

    expect(result.error).to be_a(Points::InsufficientBalance)
    expect(draft.reload).to be_drafting
    expect(draft.list).to be_nil
  end

  it "refuses sent drafts, non-authors, archived and foreign lists" do
    expect(described_class.call(draft: draft, list: list, actor: admin).error).to match(/author/)
    expect(described_class.call(draft: draft, list: create(:list), actor: member).error).to match(/company/)
    expect(described_class.call(draft: draft, list: create(:list, :archived, company: company), actor: member).error)
      .to be_a(Lists::Archived)

    sent = create(:draft_task, :sent, company: company, list: list, author: member)
    expect(described_class.call(draft: sent, list: list, actor: member).error).to be_a(DraftTasks::WrongState)
  end

  it "reports a busy lock instead of raising" do
    lock = RedisLock.new("locks:draft_task:#{draft.id}", ttl: 5)
    lock.acquire

    result = described_class.call(draft: draft, list: list, actor: member)

    expect(result.error).to be_a(DraftTasks::Services::WithLockedDraft::Lock::Busy)
    lock.release
  end
end
