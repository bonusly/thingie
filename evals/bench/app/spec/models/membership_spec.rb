require "rails_helper"

RSpec.describe Membership do
  let(:company) { create(:company, weekly_points_budget: 80) }

  it "allows one membership per user and company" do
    user = create(:user)
    create(:membership, company: company, user: user)
    expect(build(:membership, company: company, user: user)).not_to be_valid
  end

  describe "#points_budget" do
    it "uses the company budget by default" do
      expect(create(:membership, company: company).points_budget).to eq(80)
    end

    it "prefers an override when one is set" do
      membership = create(:membership, :with_budget_override, company: company)
      expect(membership.points_budget).to eq(40)
    end
  end

  describe "#remove!" do
    it "leaves the active scope and records when" do
      membership = create(:membership, company: company)
      membership.remove!
      expect(membership.removed_at).to be_present
      expect(described_class.active).not_to include(membership)
    end
  end

  describe "#promote! and #demote!" do
    it "toggles the role" do
      membership = create(:membership, company: company)
      membership.promote!
      expect(membership).to be_admin
      membership.demote!
      expect(membership).not_to be_admin
    end
  end
end
