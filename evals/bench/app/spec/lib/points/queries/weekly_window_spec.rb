require "rails_helper"

RSpec.describe Points::Queries::WeeklyWindow do
  it "starts on the company's configured weekday in its time zone" do
    company = build(:company, time_zone: "America/Denver", week_starts_on: 0)
    window = described_class.call(company: company, now: Time.utc(2026, 10, 15, 3, 0))

    expect(window.starts_at).to eq(Time.find_zone("America/Denver").local(2026, 10, 11))
    expect(window.ends_at).to eq(window.starts_at + 7.days)
  end

  it "uses Monday by default" do
    window = described_class.call(company: build(:company), now: Time.utc(2026, 10, 14, 12))
    expect(window.starts_at.wday).to eq(1)
    expect(window.starts_at.to_date).to eq(Date.new(2026, 10, 12))
  end

  it "formats the key as an ISO week" do
    window = described_class.call(company: build(:company), now: Time.utc(2026, 10, 14, 12))
    expect(window.key).to eq("2026-W42")
  end

  it "knows whether a time falls inside it" do
    window = described_class.call(company: build(:company), now: Time.utc(2026, 10, 14, 12))
    expect(window.cover?(Time.utc(2026, 10, 18, 23))).to be(true)
    expect(window.cover?(Time.utc(2026, 10, 19, 0))).to be(false)
  end
end
