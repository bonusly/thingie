require "rails_helper"

RSpec.describe "Lists API" do
  include_context "with a company and members"

  describe "GET /api/v1/lists" do
    it "includes counts" do
      list = create(:list, company: company, owner: admin)
      create(:task, company: company, list: list, author: admin)
      create(:draft_task, company: company, list: list, author: member, attached_at: 1.hour.ago)

      api_get "/api/v1/lists", user: member, company: company

      expect(json.first).to include(
        "id" => list.id.to_s, "open_task_count" => 1, "ready_draft_count" => 0, "attached_draft_count" => 1, "member_count" => 1
      )
    end

    it "leaves out deleted lists" do
      create(:list, :deleted, company: company, owner: admin)
      api_get "/api/v1/lists", user: member, company: company
      expect(json).to eq([])
    end
  end

  describe "POST /api/v1/lists" do
    it "creates a list owned by the caller" do
      api_post "/api/v1/lists", user: member, company: company, params: { list: { name: "Q4 launch", visibility: "private" } }

      expect(response).to have_http_status(:created)
      expect(json["owner_id"]).to eq(member.id.to_s)
      expect(json["slug"]).to eq("q4-launch")
    end
  end

  describe "POST /api/v1/lists/:id/deliver" do
    it "delivers for members and forbids others" do
      list = create(:list, company: company, owner: admin, member_ids: [admin.id])

      api_post "/api/v1/lists/#{list.id}/deliver", user: member, company: company
      expect(response).to have_http_status(:forbidden)

      api_post "/api/v1/lists/#{list.id}/deliver", user: admin, company: company
      expect(response).to have_http_status(:ok)
      expect(json["delivered_at"]).to be_present
    end
  end

  describe "DELETE /api/v1/lists/:id" do
    it "deletes for the owner, releases drafts and 404s afterwards" do
      list = create(:list, company: company, owner: member)
      draft = create(:draft_task, :ready, company: company, list: list, author: admin, attached_at: 1.hour.ago)

      api_delete "/api/v1/lists/#{list.id}", user: member, company: company
      expect(response).to have_http_status(:no_content)
      expect(draft.reload).to be_drafting

      api_get "/api/v1/lists/#{list.id}", user: member, company: company
      expect(response).to have_http_status(:not_found)
    end

    it "forbids members who do not own the list" do
      list = create(:list, company: company, owner: admin)
      api_delete "/api/v1/lists/#{list.id}", user: member, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/lists/:id/archive" do
    it "archives for the owner and reports a second attempt" do
      list = create(:list, company: company, owner: member)
      api_post "/api/v1/lists/#{list.id}/archive", user: member, company: company
      expect(json["state"]).to eq("archived")

      api_post "/api/v1/lists/#{list.id}/archive", user: member, company: company
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it "finds lists by slug" do
    create(:list, company: company, owner: admin, name: "Roadmap")
    api_get "/api/v1/lists/roadmap", user: member, company: company
    expect(json["name"]).to eq("Roadmap")
  end
end
