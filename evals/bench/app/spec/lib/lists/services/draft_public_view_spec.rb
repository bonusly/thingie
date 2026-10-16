require "rails_helper"

RSpec.describe Lists::Services::DraftPublicView do
  include_context "with a list and a ready draft"

  let(:share_link) { create(:share_link, :with_drafts, company: company, list: list, created_by: admin) }

  it "shows the author for a shared draft" do
    view = described_class.call(draft: draft, share_link: share_link)
    expect(view).to have_attributes(id: draft.id.to_s, title: draft.title, author_name: member.display_name, points: 10, state: "ready")
  end

  it "hides the author for a private draft" do
    draft.update!(visibility: "private")
    view = described_class.call(draft: draft, share_link: share_link)
    expect(view.author_name).to be_nil
    expect(view.title).to eq(draft.title)
  end

  it "returns nothing when the link does not show drafts" do
    link = create(:share_link, company: company, list: list, created_by: admin)
    expect(described_class.call(draft: draft, share_link: link)).to be_nil
  end

  it "returns nothing for a draft on another list or already sent" do
    other = create(:draft_task, :ready, company: company, author: member)
    expect(described_class.call(draft: other, share_link: share_link)).to be_nil

    draft.mark_sent!(create(:task, company: company, list: list))
    expect(described_class.call(draft: draft, share_link: share_link)).to be_nil
  end
end
