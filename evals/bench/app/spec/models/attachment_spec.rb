require "rails_helper"

RSpec.describe Attachment do
  it "rejects files over the size limit" do
    expect(build(:attachment, :oversized)).not_to be_valid
  end

  it "requires a unique storage key" do
    existing = create(:attachment)
    expect(build(:attachment, storage_key: existing.storage_key)).not_to be_valid
  end

  describe "#image?" do
    it "is based on the content type" do
      expect(build(:attachment, :image)).to be_image
      expect(build(:attachment)).not_to be_image
    end
  end

  describe "#extension" do
    it "lowercases the file extension without the dot" do
      expect(build(:attachment, filename: "Report.PDF").extension).to eq("pdf")
    end
  end

  describe "#human_size" do
    it "formats bytes for display" do
      expect(build(:attachment, byte_size: 42_000).human_size).to eq("41 KB")
    end
  end
end
