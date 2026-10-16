require "rails_helper"

RSpec.describe TaskPolicy do
  include_context "with a company and members"

  let(:list) { create(:list, :private, company: company, owner: admin, member_ids: [admin.id, member.id]) }
  let(:task) { create(:task, company: company, list: list, author: admin, assignee_ids: [member.id]) }

  def policy(user, record = task)
    described_class.new(user, record, membership: user.membership_for(company))
  end

  it "lets list members see tasks on private lists" do
    expect(policy(member).show?).to be(true)
    expect(policy(outsider).show?).to be(false)
  end

  it "lets assignees complete but not archive" do
    expect(policy(member).complete?).to be(true)
    expect(policy(member).archive?).to be(false)
  end

  it "lets the author and admins archive" do
    expect(policy(admin).archive?).to be(true)
  end

  it "requires list membership to create" do
    other_list = create(:list, :private, company: company, owner: admin)
    expect(policy(member, Task.new(company: company, list: other_list)).create?).to be(false)
    expect(policy(member, Task.new(company: company, list: list)).create?).to be(true)
  end

  it "denies everything across companies" do
    create(:membership, company: create(:company), user: outsider)
    foreign = described_class.new(outsider, task, membership: outsider.memberships.first)
    expect(foreign.show?).to be(false)
    expect(foreign.update?).to be(false)
  end
end
