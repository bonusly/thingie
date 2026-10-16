require "rails_helper"

RSpec.describe ListPolicy do
  include_context "with a company and members"

  def policy(user, list)
    described_class.new(user, list, membership: user.membership_for(company))
  end

  it "shows company and public lists to any member" do
    expect(policy(member, create(:list, company: company, owner: admin)).show?).to be(true)
    expect(policy(member, create(:list, :public, company: company, owner: admin)).show?).to be(true)
  end

  it "hides private lists from non-members of the list" do
    list = create(:list, :private, company: company, owner: admin)
    expect(policy(member, list).show?).to be(false)
    list.add_member(member)
    expect(policy(member, list.reload).show?).to be(true)
  end

  it "only lets owners and admins update, and only archived lists be destroyed" do
    list = create(:list, company: company, owner: member)
    expect(policy(member, list).update?).to be(true)
    expect(policy(admin, list).update?).to be(true)
    expect(policy(member, list).destroy?).to be(false)
    list.archive!
    expect(policy(member, list).destroy?).to be(true)
  end

  it "requires list membership and an active list to deliver" do
    list = create(:list, company: company, owner: admin)
    expect(policy(member, list).deliver?).to be(false)
    list.add_member(member)
    expect(policy(member, list.reload).deliver?).to be(true)
    list.archive!
    expect(policy(member, list).deliver?).to be(false)
  end
end
