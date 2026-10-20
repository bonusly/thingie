require "rails_helper"

RSpec.describe Points::Commands::ReleaseStaleReservations do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }
  let!(:held) { create(:draft_task, :ready, company: company, list: list, author: member, points: 10) }
  let!(:gone) { create(:draft_task, :ready, company: company, list: list, author: outsider, points: 10) }

  before { create(:membership, :removed, company: company, user: outsider) }

  it "releases drafts whose author no longer has an active membership" do
    result = described_class.call(company: company)

    expect(result.value).to eq(released: 1)
    expect(gone.reload).to be_drafting
    expect(held.reload).to be_ready
  end

  it "leaves sent drafts and drafts without points alone" do
    create(:draft_task, :sent_to_task, company: company, list: list, author: outsider, points: 5)
    create(:draft_task, :ready, company: company, list: list, author: outsider, points: 0)

    expect(described_class.call(company: company).value).to eq(released: 1)
  end

  it "releases nothing when every author is still active" do
    gone.destroy!
    expect(described_class.call(company: company).value).to eq(released: 0)
  end

  it "ignores other companies" do
    create(:draft_task, :ready, points: 10)
    expect(described_class.call(company: company).value).to eq(released: 1)
  end
end
