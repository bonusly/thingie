require "rails_helper"

RSpec.describe "Notifications API" do
  include_context "with a company and members"

  let!(:unread) { create(:notification, company: company, recipient: member) }
  let!(:read) { create(:notification, :read, company: company, recipient: member, created_at: 1.day.ago) }

  it "lists notifications with an unread count header" do
    api_get "/api/v1/notifications", user: member, company: company

    expect(json.map { |n| n["id"] }).to eq([unread.id.to_s, read.id.to_s])
    expect(response.headers["X-Unread-Count"]).to eq("1")
    expect(json.first["title"]).to include("Write the release notes")
  end

  it "marks one as read" do
    api_post "/api/v1/notifications/#{unread.id}/mark_read", user: member, company: company
    expect(json["read"]).to be(true)
  end

  it "marks all as read" do
    api_post "/api/v1/notifications/mark_all_read", user: member, company: company
    expect(json).to eq("marked" => 1)
  end

  it "does not expose other users' notifications" do
    api_get "/api/v1/notifications/#{unread.id}", user: admin, company: company
    expect(response).to have_http_status(:not_found)
  end
end
