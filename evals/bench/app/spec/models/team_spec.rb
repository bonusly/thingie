require "rails_helper"

RSpec.describe Team do
  let(:company) { create(:company) }

  it "has a unique name per company" do
    create(:team, company: company, name: "Platform")
    expect(build(:team, company: company, name: "Platform")).not_to be_valid
    expect(build(:team, company: create(:company), name: "Platform")).to be_valid
  end

  describe "#add_member" do
    it "adds each user once" do
      team = create(:team, company: company)
      user = create(:user)
      team.add_member(user)
      team.add_member(user)
      expect(team.reload.size).to eq(1)
      expect(team).to be_member(user)
    end
  end

  describe "#lead" do
    it "returns the lead user when set" do
      lead = create(:user)
      expect(create(:team, company: company, lead_id: lead.id).lead).to eq(lead)
      expect(create(:team, company: company).lead).to be_nil
    end
  end

  describe ".with_member" do
    it "finds teams containing the user" do
      user = create(:user)
      team = create(:team, company: company, member_ids: [user.id])
      create(:team, company: company)
      expect(described_class.with_member(user).to_a).to eq([team])
    end
  end
end
