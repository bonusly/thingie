require "rails_helper"

RSpec.describe Connectors::Services::PageLimit do
  it "yields page numbers until the block returns false" do
    seen = []
    pages = described_class.call { |page| seen << page; page < 3 }
    expect(seen).to eq([1, 2, 3])
    expect(pages).to eq(3)
  end

  it "stops at the configured maximum even when more pages remain" do
    seen = []
    pages = described_class.call { |page| seen << page; true }
    expect(seen).to eq([1, 2, 3, 4, 5])
    expect(pages).to eq(described_class::MAX_PAGES)
  end

  it "accepts an explicit maximum and never goes below one page" do
    expect(described_class.call(max: 2) { true }).to eq(2)
    expect(described_class.call(max: 0) { true }).to eq(1)
  end

  it "reads the default from configuration" do
    expect(described_class.max_pages).to eq(Rails.application.config.x.connectors.max_pages_per_call)
  end

  describe ".capped?" do
    it "is true once the walk used every page it was allowed" do
      expect(described_class.capped?(5)).to be(true)
      expect(described_class.capped?(4)).to be(false)
      expect(described_class.capped?(2, max: 2)).to be(true)
    end
  end
end
