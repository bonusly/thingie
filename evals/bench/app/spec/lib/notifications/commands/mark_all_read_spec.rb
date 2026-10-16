require "rails_helper"

RSpec.describe Notifications::Commands::MarkAllRead do
  include_context "with a company and members"

  it "marks the user's unread notifications in this company" do
    mine = create_list(:notification, 2, company: company, recipient: member)
    create(:notification, company: company, recipient: admin)
    elsewhere = create(:notification, recipient: member)

    result = described_class.call(user: member, company: company)

    expect(result.value).to eq(marked: 2)
    expect(mine.map { |n| n.reload.read? }).to all(be(true))
    expect(elsewhere.reload).not_to be_read
  end

  it "leaves notifications newer than the cutoff alone" do
    newer = create(:notification, company: company, recipient: member)
    described_class.call(user: member, company: company, before: 1.hour.ago)
    expect(newer.reload).not_to be_read
  end
end
