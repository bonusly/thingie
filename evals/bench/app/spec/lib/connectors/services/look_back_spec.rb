require "rails_helper"

RSpec.describe Connectors::Services::LookBack do
  let(:now) { Time.utc(2026, 10, 16, 12) }

  it "uses the override when given" do
    account = build(:connector_account, last_synced_at: now - 1.hour)
    expect(described_class.call(account: account, override: now - 2.days, now: now)).to eq(now - 2.days)
  end

  it "falls back to the default window for never-synced accounts" do
    account = build(:connector_account, last_synced_at: nil)
    expect(described_class.call(account: account, now: now)).to eq(now - described_class::DEFAULT_WINDOW)
  end

  it "overlaps the last sync slightly" do
    account = build(:connector_account, last_synced_at: now - 1.hour)
    expect(described_class.call(account: account, now: now)).to eq(now - 1.hour - described_class::OVERLAP)
  end

  it "never looks back further than the default window" do
    account = build(:connector_account, last_synced_at: now - 30.days)
    expect(described_class.call(account: account, now: now)).to eq(now - described_class::DEFAULT_WINDOW)
  end
end
