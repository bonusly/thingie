require "rails_helper"

RSpec.describe Lists::Queries::ListLists do
  include_context "with a company and members"

  let!(:second) { create(:list, company: company, owner: admin, name: "Beta", position: 2) }
  let!(:first) { create(:list, company: company, owner: admin, name: "Alpha", position: 1) }
  let!(:archived) { create(:list, :archived, company: company, owner: admin, position: 0) }
  let!(:hidden) { create(:list, :private, company: company, owner: admin) }

  it "returns visible active lists in position order" do
    expect(described_class.call(company: company, user: member).to_a).to eq([first, second])
  end

  it "includes archived lists on request" do
    expect(described_class.call(company: company, user: member, include_archived: true).to_a).to eq([archived, first, second])
  end

  it "shows private lists to their owner" do
    expect(described_class.call(company: company, user: admin)).to include(hidden)
  end
end
