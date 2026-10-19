require "rails_helper"

RSpec.describe DraftTasks::Commands::MarkReady do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }
  let(:draft) { create(:draft_task, company: company, author: member, list: list, attached_at: 1.hour.ago, points: 30) }

  it "moves an attached draft to ready and reserves its points" do
    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_ready
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(30)
  end

  it "fails for a draft that is not on a list" do
    loose = create(:draft_task, company: company, author: member, points: 5)
    result = described_class.call(draft: loose, actor: member)
    expect(result.error).to be_a(DraftTasks::NotAttached)
    expect(loose.reload).to be_drafting
  end

  it "fails when the remaining budget cannot cover the points" do
    create(:draft_task, :ready, company: company, list: list, author: member, points: 80)

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

    expect(result.error).to be_a(DraftTasks::Services::WithLockedDraft::Lock::Busy)
    lock.release
  end
end
