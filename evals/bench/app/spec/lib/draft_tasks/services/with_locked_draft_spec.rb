require "rails_helper"

RSpec.describe DraftTasks::Services::WithLockedDraft do
  let(:draft) { create(:draft_task) }
  let(:key) { "locks:draft_task:#{draft.id}" }

  it "yields a fresh copy of the draft and releases the lock afterwards" do
    draft.set(title: "changed elsewhere")

    yielded = described_class.call(draft) { |locked| locked }

    expect(yielded.title).to eq("changed elsewhere")
    expect(AppRedis.with { |redis| redis.exists?(key) }).to be(false)
  end

  it "raises Lock::Busy when another holder has the key" do
    other = RedisLock.new(key, ttl: 5)
    other.acquire

    expect { described_class.call(draft) { raise "should not run" } }
      .to raise_error(described_class::Lock::Busy, /#{draft.id}/)
  ensure
    other.release
  end

  it "releases the lock even when the block raises" do
    expect { described_class.call(draft) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
    expect(AppRedis.with { |redis| redis.exists?(key) }).to be(false)
  end

  it "returns the block's value" do
    expect(described_class.call(draft) { :done }).to eq(:done)
  end
end
