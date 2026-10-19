require "rails_helper"

RSpec.describe RouteIndexEntry do
  it "requires an absolute path" do
    expect(build(:route_index_entry, path: "tasks")).not_to be_valid
  end

  it "keeps one entry per path" do
    existing = create(:route_index_entry)
    expect(build(:route_index_entry, path: existing.path)).not_to be_valid
  end

  describe ".gated and .open_access" do
    it "split entries by permission" do
      gated = create(:route_index_entry, :gated)
      open = create(:route_index_entry)
      expect(described_class.gated.to_a).to eq([gated])
      expect(described_class.open_access.to_a).to eq([open])
    end
  end

  describe "#stale?" do
    it "is true when indexed before the cutoff or never" do
      expect(build(:route_index_entry, :stale).stale?(since: 1.day.ago)).to be(true)
      expect(build(:route_index_entry, indexed_at: nil).stale?(since: 1.day.ago)).to be(true)
      expect(build(:route_index_entry).stale?(since: 1.day.ago)).to be(false)
    end
  end
end
