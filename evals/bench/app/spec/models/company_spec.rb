require "rails_helper"

RSpec.describe Company do
  describe "validations" do
    it "requires a known plan" do
      company = build(:company, plan: "enterprise")
      expect(company).not_to be_valid
      expect(company.errors[:plan]).to be_present
    end

    it "rejects a week start outside 0..6" do
      expect(build(:company, week_starts_on: 7)).not_to be_valid
    end

    it "derives a slug from the name" do
      company = create(:company, name: "Acme Widgets", slug: nil)
      expect(company.slug).to eq("acme-widgets")
    end
  end

  describe "#suspend! and #unsuspend!" do
    let(:company) { create(:company) }

    it "moves between the active and suspended scopes" do
      company.suspend!
      expect(described_class.suspended).to include(company)
      expect(company).not_to be_active

      company.unsuspend!
      expect(described_class.active).to include(company)
    end
  end

  describe "#admins" do
    let(:company) { create(:company) }

    it "returns only users with an active admin membership" do
      admin = create(:membership, :admin, company: company).user
      create(:membership, company: company)
      create(:membership, :admin, :removed, company: company)

      expect(company.admins.to_a).to eq([admin])
    end
  end
end
