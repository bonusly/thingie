require "rails_helper"

RSpec.describe DraftTasks::Commands::MarkReady do
  include_context "with a company and members"

  let(:draft) { create(:draft_task, company: company, author: member, points: 30) }

  it "moves the draft to ready and holds its points in escrow" do
    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_ready
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(30)
  end

  it "fails when the remaining budget cannot cover the points" do
    create(:draft_task, :ready, company: company, author: member, points: 80)

    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_failure
    expect(result.error).to be_a(Points::InsufficientBalance)
    expect(draft.reload).to be_drafting
  end

  it "counts points already given this week against the budget" do
    create(:points_ledger_entry, company: company, user: member, amount: 75)
    expect(described_class.call(draft: draft, actor: member).error).to be_a(Points::InsufficientBalance)
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

  it "reports a busy draft lock as a failure message" do
    lock = RedisLock.new("locks:draft_task:#{draft.id}", ttl: 5)
    lock.acquire

    result = described_class.call(draft: draft, actor: member)

    expect(result.error).to match(/held by another process/)
    expect(draft.reload).to be_drafting
    lock.release
  end

  it "reports a busy giver lock as a failure message" do
    lock = RedisLock.new("locks:giver:#{company.id}:#{member.id}", ttl: 5)
    lock.acquire

    result = described_class.call(draft: draft, actor: member)

    expect(result.error).to match(/giver lock/)
    expect(draft.reload).to be_drafting
    lock.release
  end
end
