require "rails_helper"

RSpec.describe Sharing::Queries::PublicList do
  include_context "with a list and a ready draft"

  let!(:open_task) { create(:task, company: company, list: list, author: admin, position: 1) }
  let!(:archived) { create(:task, :archived, company: company, list: list, author: admin) }

  it "exposes non-archived tasks and no drafts by default" do
    link = create(:share_link, company: company, list: list, created_by: admin)
    view = described_class.call(share_link: link)

    expect(view.tasks).to eq([open_task])
    expect(view.drafts).to eq([])
  end

  it "includes ready drafts through the public view when enabled" do
    draft
    create(:draft_task, :private, :ready, company: company, list: list, author: member)
    link = create(:share_link, :with_drafts, company: company, list: list, created_by: admin)

    view = described_class.call(share_link: link)

    expect(view.drafts.size).to eq(2)
    expect(view.drafts.map(&:author_name)).to contain_exactly(member.display_name, nil)
  end

  it "includes drafts sent in the last week but not older ones" do
    draft
    recent = create(:draft_task, :sent_to_task, company: company, list: list, author: member, sent_at: 2.days.ago)
    create(:draft_task, :sent_to_task, company: company, list: list, author: member, sent_at: 9.days.ago)
    link = create(:share_link, :with_drafts, company: company, list: list, created_by: admin)

    view = described_class.call(share_link: link)

    expect(view.drafts.map(&:id)).to eq([recent.id.to_s, draft.id.to_s])
  end
end
