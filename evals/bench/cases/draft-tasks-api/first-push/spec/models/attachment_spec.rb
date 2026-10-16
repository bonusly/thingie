require "rails_helper"

RSpec.describe Attachment do
  it "rejects files over the size limit" do
    expect(build(:attachment, :oversized)).not_to be_valid
  end

  it "holds recordings to the lower media limit" do
    expect(build(:attachment, :audio, :oversized_media)).not_to be_valid
    expect(build(:attachment, byte_size: Attachment::MEDIA_MAX_BYTES + 1)).to be_valid
  end

  it "requires a unique storage key" do
    existing = create(:attachment)
    expect(build(:attachment, storage_key: existing.storage_key)).not_to be_valid
  end

  it "can wait unclaimed for a draft" do
    expect(build(:attachment, :unclaimed)).to be_valid
    expect(build(:attachment, :unclaimed)).not_to be_claimed
    expect(build(:attachment)).to be_claimed
  end

  describe "#image?" do
    it "is based on the content type" do
      expect(build(:attachment, :image)).to be_image
      expect(build(:attachment)).not_to be_image
    end
  end

  describe "#media_kind" do
    it "names audio and video and nothing else" do
      expect(build(:attachment, :audio).media_kind).to eq("audio")
      expect(build(:attachment, :video).media_kind).to eq("video")
      expect(build(:attachment).media_kind).to be_nil
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
