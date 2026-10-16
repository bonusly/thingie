require "rails_helper"

RSpec.describe ExternalItem do
  it "requires a known kind" do
    expect(build(:external_item, kind: "commit")).not_to be_valid
  end

  describe "#mark_imported!" do
    it "links the item to the task" do
      item = create(:external_item)
      task = create(:task, company: item.company)
      item.mark_imported!(task)
      expect(item.reload).to be_imported
      expect(item.imported_task).to eq(task)
    end
  end

  describe ".unimported" do
    it "excludes imported items" do
      fresh = create(:external_item)
      create(:external_item, :imported)
      expect(described_class.unimported.to_a).to eq([fresh])
    end
  end

  describe ".newest_first" do
    it "orders by the external timestamp" do
      older = create(:external_item, external_updated_at: 2.days.ago)
      newer = create(:external_item, external_updated_at: 1.hour.ago)
      expect(described_class.newest_first.to_a).to eq([newer, older])
    end
  end
end
