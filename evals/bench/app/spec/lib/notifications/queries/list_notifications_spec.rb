require "rails_helper"

RSpec.describe Notifications::Queries::ListNotifications do
  include_context "with a company and members"

  let!(:older) { create(:notification, :read, company: company, recipient: member, created_at: 2.days.ago) }
  let!(:newer) { create(:notification, company: company, recipient: member, created_at: 1.hour.ago) }

  before { create(:notification, company: company, recipient: admin) }

  it "lists the recipient's notifications newest first" do
    expect(described_class.call(user: member, company: company).to_a).to eq([newer, older])
  end

  it "can restrict to unread" do
    expect(described_class.call(user: member, company: company, unread_only: true).to_a).to eq([newer])
  end

  it "paginates" do
    expect(described_class.call(user: member, company: company, page: 2, per_page: 1).to_a).to eq([older])
  end
end
