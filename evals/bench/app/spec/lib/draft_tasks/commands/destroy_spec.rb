require "rails_helper"

RSpec.describe DraftTasks::Commands::Destroy do
  include_context "with a company and members"

  let(:draft) { create(:draft_task, company: company, author: member) }

  it "deletes a draft owned by the actor" do
    expect(described_class.call(draft: draft, actor: member)).to be_success
    expect(DraftTask.where(id: draft.id)).not_to exist
  end

  it "refuses other users even admins" do
    expect(described_class.call(draft: draft, actor: admin)).to be_failure
    expect(DraftTask.where(id: draft.id)).to exist
  end

  it "refuses sent drafts" do
    sent = create(:draft_task, :sent, company: company, author: member)
    expect(described_class.call(draft: sent, actor: member).error).to be_a(DraftTasks::WrongState)
  end
end
