require "rails_helper"

RSpec.describe "Draft tasks API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  describe "GET /api/v1/draft_tasks" do
    it "lists the caller's drafts, filtered by state" do
      create(:draft_task, company: company, list: list, author: member)
      ready = create(:draft_task, :ready, company: company, list: list, author: member)
      create(:draft_task, company: company, list: list, author: admin)

      api_get "/api/v1/draft_tasks", user: member, company: company, params: { state: "ready" }

      expect(json.map { |d| d["id"] }).to eq([ready.id.to_s])
    end
  end

  describe "POST /api/v1/draft_tasks" do
    it "creates a drafting draft" do
      api_post "/api/v1/draft_tasks", user: member, company: company,
               params: { list_id: list.id.to_s, draft_task: { title: "Plan", points: 10, note: "see doc" } }

      expect(response).to have_http_status(:created)
      expect(json).to include("state" => "drafting", "points" => 10, "editable" => true)
    end
  end

  describe "PATCH /api/v1/draft_tasks/:id" do
    it "updates an editable draft and rejects a ready one" do
      draft = create(:draft_task, company: company, list: list, author: member)
      api_patch "/api/v1/draft_tasks/#{draft.id}", user: member, company: company, params: { draft_task: { title: "New" } }
      expect(json["title"]).to eq("New")

      draft.mark_ready!
      api_patch "/api/v1/draft_tasks/#{draft.id}", user: member, company: company, params: { draft_task: { title: "Newer" } }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/draft_tasks/:id/mark_ready" do
    let(:draft) { create(:draft_task, company: company, list: list, author: member, points: 20) }

    it "reserves the points" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company
      expect(response).to have_http_status(:ok)
      expect(json).to include("state" => "ready", "reserved_points" => 20)
    end

    it "returns 422 when the budget is short" do
      create(:draft_task, :ready, company: company, list: list, author: member, points: 90)
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "forbids non-authors" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: admin, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/draft_tasks/:id" do
    it "removes the draft" do
      draft = create(:draft_task, company: company, list: list, author: member)
      api_delete "/api/v1/draft_tasks/#{draft.id}", user: member, company: company
      expect(response).to have_http_status(:no_content)
      expect(DraftTask.where(id: draft.id)).not_to exist
    end
  end
end
