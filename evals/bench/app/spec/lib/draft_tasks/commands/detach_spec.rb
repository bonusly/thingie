require "rails_helper"

RSpec.describe DraftTasks::Commands::Detach do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id]) }
  let(:draft) { create(:draft_task, company: company, author: member, points: 20) }

  before { DraftTasks::Commands::Attach.call(draft: draft, list: list, actor: member) }

  it "returns the draft to drafting, clears the list and removes the attach comment" do
    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_drafting
    expect(draft.list).to be_nil
    expect(draft.attached_at).to be_nil
    expect(list.comments.from_drafts.count).to eq(0)
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "lets a company admin detach someone else's draft" do
    expect(described_class.call(draft: draft, actor: admin)).to be_success
  end

  it "refuses other members and sent drafts" do
    expect(described_class.call(draft: draft, actor: outsider)).to be_failure
    expect(draft.reload.list).to eq(list)

    draft.mark_sent!(create(:task, company: company, list: list))
    expect(described_class.call(draft: draft, actor: member).error).to be_a(DraftTasks::WrongState)
  end

  it "is a no-op for an unattached draft" do
    loose = create(:draft_task, company: company, author: member)
    expect(described_class.call(draft: loose, actor: member)).to be_success
  end
end
