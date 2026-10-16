require "rails_helper"

RSpec.describe Points::Jobs::ReleaseStaleReservationsJob do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }

  before do
    create(:membership, :removed, company: company, user: outsider)
    create(:draft_task, :ready, company: company, list: list, author: outsider, points: 10)
  end

  it "runs the release for every active company" do
    create(:company, :suspended)

    described_class.new.perform

    expect(DraftTask.ready.count).to eq(0)
  end

  it "runs for one company when given its id" do
    other = create(:company)
    stray = create(:draft_task, :ready, company: other, points: 3)

    described_class.new.perform(company.id.to_s)

    expect(stray.reload).to be_ready
    expect(DraftTask.for_company(company).ready.count).to eq(0)
  end
end
