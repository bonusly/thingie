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

  it "includes attached drafts through the public view when enabled" do
    draft
    create(:draft_task, :private, company: company, list: list, author: member, attached_at: 5.minutes.ago)
    create(:draft_task, :sent, company: company, list: list, author: member, attached_at: 1.hour.ago)
    create(:draft_task, :ready, company: company, author: member)
    link = create(:share_link, :with_drafts, company: company, list: list, created_by: admin)

    view = described_class.call(share_link: link)

    expect(view.drafts.size).to eq(2)
    expect(view.drafts.map(&:author_name)).to eq([member.display_name, nil])
    expect(view.drafts.map(&:state)).to eq(%w[ready drafting])
  end
end
