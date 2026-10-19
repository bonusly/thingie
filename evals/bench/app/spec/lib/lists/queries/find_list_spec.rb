require "rails_helper"

RSpec.describe Lists::Queries::FindList do
  let(:company) { create(:company) }
  let(:list) { create(:list, company: company, name: "Roadmap") }

  it "finds by id" do
    expect(described_class.call(company: company, id: list.id.to_s)).to eq(list)
  end

  it "finds by slug" do
    expect(described_class.call(company: company, id: "roadmap")).to eq(list)
  end

  it "does not cross companies" do
    expect { described_class.call(company: create(:company), id: list.id) }.to raise_error(Lists::NotFound)
  end
end
