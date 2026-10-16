require "rails_helper"

RSpec.describe Invitation do
  it "defaults the expiry" do
    invitation = create(:invitation, expires_at: nil)
    expect(invitation.expires_at).to be_within(1.minute).of(Invitation::DEFAULT_TTL.from_now)
  end

  it "normalizes the email" do
    expect(create(:invitation, email: " Ada@Example.TEST").email).to eq("ada@example.test")
  end

  describe ".pending" do
    it "excludes accepted and expired invitations" do
      pending = create(:invitation)
      create(:invitation, :accepted)
      create(:invitation, :expired)
      expect(described_class.pending.to_a).to eq([pending])
    end
  end

  describe "#accept!" do
    it "creates a membership with the invited role" do
      invitation = create(:invitation, :admin)
      user = create(:user)
      membership = invitation.accept!(user)

      expect(membership.company).to eq(invitation.company)
      expect(membership).to be_admin
      expect(invitation.reload).to be_accepted
    end
  end
end
