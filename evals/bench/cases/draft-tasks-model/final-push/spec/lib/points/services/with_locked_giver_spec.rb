require "rails_helper"

RSpec.describe Points::Services::WithLockedGiver do
  let(:company) { create(:company) }
  let(:user) { create(:user) }
  let(:key) { "locks:giver:#{company.id}:#{user.id}" }

  it "runs the block and releases the lock afterwards" do
    expect(described_class.call(user: user, company: company) { :held }).to eq(:held)
    expect(AppRedis.with { |redis| redis.exists?(key) }).to be(false)
  end

  it "raises Busy when another holder has the key" do
    other = RedisLock.new(key, ttl: 5)
    other.acquire

    expect { described_class.call(user: user, company: company) { raise "should not run" } }
      .to raise_error(described_class::Busy, /#{user.id}/)
  ensure
    other.release
  end

  it "releases the lock even when the block raises" do
    expect { described_class.call(user: user, company: company) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
    expect(AppRedis.with { |redis| redis.exists?(key) }).to be(false)
  end

  it "keys the lock per company" do
    other = RedisLock.new("locks:giver:#{create(:company).id}:#{user.id}", ttl: 5)
    other.acquire

    expect(described_class.call(user: user, company: company) { :ok }).to eq(:ok)
  ensure
    other.release
  end
end
