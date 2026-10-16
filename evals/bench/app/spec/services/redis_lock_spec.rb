require "rails_helper"

RSpec.describe RedisLock do
  let(:key) { "locks:spec:#{SecureRandom.hex(4)}" }

  it "acquires once and refuses a second holder" do
    first = described_class.new(key, ttl: 5)
    second = described_class.new(key, ttl: 5)

    expect(first.acquire).to be(true)
    expect(second.acquire).to be(false)
    expect(first).to be_held
  end

  it "only lets the holder release" do
    first = described_class.new(key, ttl: 5)
    second = described_class.new(key, ttl: 5)
    first.acquire

    expect(second.release).to be(false)
    expect(first.release).to be(true)
    expect(second.acquire).to be(true)
  end

  it "expires after the ttl" do
    lock = described_class.new(key, ttl: 1)
    lock.acquire
    sleep 1.1
    expect(described_class.new(key, ttl: 1).acquire).to be(true)
  end
end
