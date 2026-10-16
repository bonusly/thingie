require "rails_helper"

RSpec.describe Comments::Services::MentionParser do
  include_context "with a company and members"

  let!(:ada) { create(:membership, company: company, user: create(:user, email: "ada.l@example.test")).user }

  it "maps handles to member ids" do
    ids = described_class.call(company: company, body: "ping @ada.l and @Ada.L again")
    expect(ids).to eq([ada.id])
  end

  it "ignores handles that are not members and emails" do
    create(:user, email: "ghost@example.test")
    expect(described_class.call(company: company, body: "@ghost or mail me at me@ada.l")).to eq([])
  end

  it "returns an empty list for blank bodies" do
    expect(described_class.call(company: company, body: nil)).to eq([])
  end
end
