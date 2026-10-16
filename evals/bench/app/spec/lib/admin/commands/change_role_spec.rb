require "rails_helper"

RSpec.describe Admin::Commands::ChangeRole do
  include_context "with a company and members"

  it "lets a company admin promote a member" do
    result = described_class.call(membership: member_membership, actor: admin, role: "admin")
    expect(result).to be_success
    expect(member_membership.reload).to be_admin
  end

  it "lets staff act without a membership" do
    staff = create(:user, :staff)
    expect(described_class.call(membership: member_membership, actor: staff, role: "admin")).to be_success
  end

  it "refuses to demote the last admin" do
    result = described_class.call(membership: admin_membership, actor: admin, role: "member")
    expect(result.error).to match(/last admin/)
  end

  it "refuses plain members and unknown roles" do
    expect(described_class.call(membership: admin_membership, actor: member, role: "member")).to be_failure
    expect(described_class.call(membership: member_membership, actor: admin, role: "owner")).to be_failure
  end
end
