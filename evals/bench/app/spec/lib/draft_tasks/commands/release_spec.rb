require "rails_helper"

RSpec.describe DraftTasks::Commands::Release do
  include_context "with a list and a ready draft"

  it "returns a ready draft to drafting and frees the escrow" do
    result = described_class.call(draft: draft, actor: member)

    expect(result).to be_success
    expect(draft.reload).to be_drafting
    expect(draft.ready_at).to be_nil
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "lets a company admin release someone else's draft" do
    expect(described_class.call(draft: draft, actor: admin)).to be_success
  end

  it "refuses other members" do
    result = described_class.call(draft: draft, actor: outsider)
    expect(result).to be_failure
    expect(draft.reload).to be_ready
  end

  it "is a no-op for a drafting draft" do
    draft.release_reservation!
    expect(described_class.call(draft: draft, actor: member)).to be_success
  end

  it "cannot release a sent draft" do
    draft.mark_sent!(create(:task, company: company, list: list))
    expect(described_class.call(draft: draft, actor: member).error).to be_a(DraftTasks::WrongState)
  end
end
