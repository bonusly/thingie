require "rails_helper"

RSpec.describe Sharing::Commands::CreateShareLink do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  it "creates a link with the default ttl" do
    result = described_class.call(list: list, actor: member)

    expect(result).to be_success
    link = result.value
    expect(link.expires_at).to be_within(1.minute).of(Rails.application.config.x.share_links.default_ttl.from_now)
    expect(link.show_drafts).to be(false)
    expect(AuditLog.for_target(link).count).to eq(1)
  end

  it "accepts a custom ttl and draft visibility" do
    link = described_class.call(list: list, actor: admin, ttl: 2.days, show_drafts: true).value
    expect(link.expires_at).to be_within(1.minute).of(2.days.from_now)
    expect(link.show_drafts).to be(true)
  end

  it "refuses non-members and archived lists" do
    expect(described_class.call(list: list, actor: outsider).error).to be_a(Lists::NotAMember)
    list.archive!
    expect(described_class.call(list: list, actor: admin).error).to be_a(Sharing::NotShareable)
  end
end
