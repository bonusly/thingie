require "rails_helper"

RSpec.describe List do
  let(:company) { create(:company) }

  describe "state machine" do
    it "archives and restores" do
      list = create(:list, company: company)
      list.archive!
      expect(list).to be_archived
      list.restore!
      expect(list).to be_active
    end

    it "cannot archive twice" do
      list = create(:list, :archived, company: company)
      expect { list.archive! }.to raise_error(AASM::InvalidTransition)
    end
  end

  describe ".visible_to" do
    let(:user) { create(:user) }

    it "includes company, public, owned and member lists but not private ones" do
      company_list = create(:list, company: company)
      private_list = create(:list, :private, company: company)
      joined = create(:list, :private, company: company, member_ids: [user.id])
      owned = create(:list, :private, company: company, owner: user)

      visible = described_class.for_company(company).visible_to(user).to_a
      expect(visible).to include(company_list, joined, owned)
      expect(visible).not_to include(private_list)
    end
  end

  describe ".not_deleted and #deleted?" do
    it "hides deleted lists" do
      live = create(:list, company: company)
      gone = create(:list, :deleted, company: company)
      expect(described_class.not_deleted.to_a).to eq([live])
      expect(gone).to be_deleted
    end
  end

  describe "#members" do
    it "includes the authors of attached drafts alongside member_ids" do
      list = create(:list, company: company)
      contributor = create(:user)
      create(:draft_task, company: company, list: list, author: contributor, attached_at: 1.hour.ago)
      create(:draft_task, :sent, company: company, list: list, author: create(:user))

      expect(list.members.to_a).to contain_exactly(list.owner, contributor)
      expect(list).not_to be_member(contributor)
    end
  end

  describe "#add_member and #remove_member" do
    it "keeps member_ids unique" do
      list = create(:list, company: company)
      user = create(:user)
      list.add_member(user)
      list.add_member(user)
      expect(list.reload.member_ids.count(user.id)).to eq(1)
      list.remove_member(user)
      expect(list.reload).not_to be_member(user)
    end
  end

  it "keeps drafts when the list document goes away" do
    list = create(:list, company: company)
    draft = create(:draft_task, company: company, list: list)
    list.destroy!
    expect(draft.reload.list_id).to be_nil
  end

  it "scopes slugs to the company" do
    create(:list, company: company, name: "Launch")
    other = create(:list, company: create(:company), name: "Launch")
    expect(other.slug).to eq("launch")
    expect(create(:list, company: company, name: "Launch").slug).to eq("launch-2")
  end
end
