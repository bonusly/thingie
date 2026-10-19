require "rails_helper"

RSpec.describe DraftTaskPolicy do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }
  let(:draft) { create(:draft_task, company: company, list: list, author: member) }

  before { enable_feature(:draft_tasks) }

  def policy(user, record = draft)
    described_class.new(user, record, membership: user.membership_for(company))
  end

  it "lets the author edit while drafting only" do
    expect(policy(member).update?).to be(true)
    draft.mark_ready!
    expect(policy(member).update?).to be(false)
  end

  it "shows shared drafts to list members and hides private ones" do
    expect(policy(admin).show?).to be(true)
    draft.update!(visibility: "private")
    expect(policy(admin).show?).to be(true)
    create(:membership, company: company, user: outsider)
    expect(policy(outsider).show?).to be(false)
  end

  it "allows release and send_now for admins but mark_ready only for the author" do
    expect(policy(admin).mark_ready?).to be(false)
    expect(policy(member).mark_ready?).to be(true)
    draft.mark_ready!
    expect(policy(admin).release?).to be(true)
    expect(policy(admin).send_now?).to be(true)
  end

  it "does not let anyone reserve points while the feature is off" do
    enable_feature(:draft_tasks, everyone: false)
    expect(policy(member).mark_ready?).to be(false)
  end

  it "never allows destroying a sent draft" do
    sent = create(:draft_task, :sent, company: company, list: list, author: member)
    expect(policy(member, sent).destroy?).to be(false)
  end
end
