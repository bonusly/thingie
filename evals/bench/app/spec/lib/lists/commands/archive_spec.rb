require "rails_helper"

RSpec.describe Lists::Commands::Archive do
  include_context "with a list and a ready draft"

  it "archives the list, revokes share links and releases ready drafts" do
    link = create(:share_link, company: company, list: list, created_by: admin)

    result = described_class.call(list: list, actor: admin)

    expect(result).to be_success
    expect(list.reload).to be_archived
    expect(link.reload).not_to be_active
    expect(draft.reload).to be_drafting
  end

  it "fails when already archived" do
    list.archive!
    expect(described_class.call(list: list, actor: admin).error).to be_a(Lists::Archived)
  end
end
