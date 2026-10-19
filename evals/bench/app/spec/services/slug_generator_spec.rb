require "rails_helper"

RSpec.describe SlugGenerator do
  it "returns the base when free" do
    expect(described_class.unique("launch") { false }).to eq("launch")
  end

  it "appends a counter until a free slug is found" do
    taken = %w[launch launch-2]
    expect(described_class.unique("launch") { |candidate| taken.include?(candidate) }).to eq("launch-3")
  end

  it "falls back to a random suffix after too many attempts" do
    slug = described_class.unique("launch") { true }
    expect(slug).to match(/\Alaunch-[0-9a-f]{8}\z/)
  end

  it "uses a placeholder for blank bases" do
    expect(described_class.unique("") { false }).to eq("item")
  end
end
