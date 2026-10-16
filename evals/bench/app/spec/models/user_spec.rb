require "rails_helper"

RSpec.describe User do
  describe "email normalization" do
    it "strips and downcases before validation" do
      user = create(:user, email: "  Ada@Example.TEST ")
      expect(user.email).to eq("ada@example.test")
    end

    it "rejects duplicates regardless of case" do
      create(:user, email: "ada@example.test")
      expect(build(:user, email: "ADA@example.test")).not_to be_valid
    end
  end

  describe "#membership_for" do
    let(:user) { create(:user) }
    let(:company) { create(:company) }

    it "ignores removed memberships" do
      create(:membership, :removed, company: company, user: user)
      expect(user.membership_for(company)).to be_nil
      expect(user).not_to be_member_of(company)
    end

    it "reports admin status for the given company" do
      create(:membership, :admin, company: company, user: user)
      expect(user.admin_of?(company)).to be(true)
      expect(user.admin_of?(create(:company))).to be(false)
    end
  end

  describe "#display_name" do
    it "falls back to the mailbox when the name is blank" do
      user = build(:user, email: "grace@example.test", name: "")
      expect(user.display_name).to eq("grace")
    end
  end
end
