require "rails_helper"

RSpec.describe Lists::Commands::Destroy do
  include_context "with a list and a ready draft"

  it "marks the list deleted, releases its drafts and drops their attach comments" do
    draft
    create(:comment, company: company, commentable: list, author: member, draft_task_id: draft.id, body: "Attached a draft")
    create(:comment, company: company, commentable: list, author: admin, body: "Kickoff notes")
    link = create(:share_link, company: company, list: list, created_by: admin)

    result = described_class.call(list: list, actor: admin)

    expect(result).to be_success
    expect(list.reload).to be_deleted
    expect(draft.reload).to be_drafting
    expect(draft.list).to be_nil
    expect(draft.attached_at).to be_nil
    expect(list.comments.count).to eq(1)
    expect(link.reload).not_to be_active
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "leaves sent drafts pointing at the list they were sent from" do
    sent = create(:draft_task, :sent, company: company, list: list, author: member)
    described_class.call(list: list, actor: admin)
    expect(sent.reload.list_id).to eq(list.id)
  end

  it "records the audit entry with the release count" do
    draft
    described_class.call(list: list, actor: admin)
    entry = AuditLog.for_target(list).where(action: "list.deleted").first
    expect(entry.details).to eq("released" => 1)
  end

  it "fails when the list is already deleted" do
    described_class.call(list: list, actor: admin)
    expect(described_class.call(list: list.reload, actor: admin)).to be_failure
  end

  it "hides the list from finders afterwards" do
    described_class.call(list: list, actor: admin)
    expect { Lists::Queries::FindList.call(company: company, id: list.id) }.to raise_error(Lists::NotFound)
    expect(Lists::Queries::ListLists.call(company: company, user: admin).to_a).to eq([])
  end
end
