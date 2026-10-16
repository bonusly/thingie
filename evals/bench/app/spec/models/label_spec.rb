require "rails_helper"

RSpec.describe Label do
  let(:company) { create(:company) }

  it "requires a hex color" do
    expect(build(:label, color: "red")).not_to be_valid
    expect(build(:label, color: "#A1B2C3")).to be_valid
  end

  it "is unique per company ignoring case" do
    create(:label, company: company, name: "Bug")
    expect(build(:label, company: company, name: "bug")).not_to be_valid
    expect(build(:label, company: create(:company), name: "bug")).to be_valid
  end

  describe "#task_count" do
    it "counts non-archived tasks carrying the label" do
      label = create(:label, company: company)
      list = create(:list, company: company)
      create(:task, company: company, list: list, label_ids: [label.id])
      create(:task, :archived, company: company, list: list, label_ids: [label.id])
      create(:task, company: company, list: list)

      expect(label.task_count).to eq(1)
    end
  end
end
