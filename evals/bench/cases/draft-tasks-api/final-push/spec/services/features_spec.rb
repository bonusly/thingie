require "rails_helper"

RSpec.describe Features do
  let(:company) { create(:company, slug: "acme") }
  let(:user) { create(:user, email: "dana@acme.test") }

  it "is off for everyone when the flag has no rule" do
    expect(described_class.enabled?(:nope, company)).to be(false)
    expect(described_class.enabled?(:nope, user)).to be(false)
  end

  it "is on for every subject when the rule says everyone" do
    enable_feature(:draft_tasks, everyone: true)
    expect(described_class.enabled?(:draft_tasks, company)).to be(true)
    expect(described_class.enabled?(:draft_tasks, user)).to be(true)
  end

  it "matches a company by slug" do
    enable_feature(:draft_tasks, companies: ["acme"])
    expect(described_class.enabled?(:draft_tasks, company)).to be(true)
    expect(described_class.enabled?(:draft_tasks, create(:company, slug: "globex"))).to be(false)
  end

  it "matches a user by email" do
    enable_feature(:draft_tasks, users: ["dana@acme.test"])
    expect(described_class.enabled?(:draft_tasks, user)).to be(true)
    expect(described_class.enabled?(:draft_tasks, create(:user))).to be(false)
  end

  it "ignores subjects it does not know how to target" do
    enable_feature(:draft_tasks, companies: ["acme"])
    expect(described_class.enabled?(:draft_tasks, create(:list, company: company))).to be(false)
  end
end
