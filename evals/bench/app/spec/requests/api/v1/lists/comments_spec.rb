require "rails_helper"

RSpec.describe "List comments API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }

  describe "GET /api/v1/lists/:list_id/comments" do
    it "returns comments oldest first and supports since" do
      old = create(:comment, company: company, commentable: list, author: admin, created_at: 2.hours.ago)
      recent = create(:comment, company: company, commentable: list, author: member, created_at: 10.minutes.ago)
      create(:comment, company: company, author: member)

      api_get "/api/v1/lists/#{list.id}/comments", user: member, company: company
      expect(json.map { |c| c["id"] }).to eq([old.id.to_s, recent.id.to_s])

      api_get "/api/v1/lists/#{list.id}/comments", user: member, company: company, params: { since: 1.hour.ago.iso8601 }
      expect(json.map { |c| c["id"] }).to eq([recent.id.to_s])
    end

    it "hides private lists the caller is not on" do
      hidden = create(:list, :private, company: company, owner: admin)
      api_get "/api/v1/lists/#{hidden.id}/comments", user: member, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/lists/:list_id/comments" do
    it "creates a comment on the list" do
      api_post "/api/v1/lists/#{list.id}/comments", user: member, company: company, params: { comment: { body: "Kickoff Monday" } }

      expect(response).to have_http_status(:created)
      expect(json).to include("commentable_type" => "List", "commentable_id" => list.id.to_s, "from_draft" => false)
    end

    it "returns 422 for an empty body" do
      api_post "/api/v1/lists/#{list.id}/comments", user: member, company: company, params: { comment: { body: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
