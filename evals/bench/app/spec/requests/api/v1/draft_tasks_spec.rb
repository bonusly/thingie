require "rails_helper"

RSpec.describe "Draft tasks API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  describe "GET /api/v1/draft_tasks" do
    it "lists the caller's drafts, filtered by state" do
      create(:draft_task, company: company, author: member)
      ready = create(:draft_task, :ready, company: company, list: list, author: member)
      create(:draft_task, company: company, list: list, author: admin)

      api_get "/api/v1/draft_tasks", user: member, company: company, params: { state: "ready" }

      expect(json.map { |d| d["id"] }).to eq([ready.id.to_s])
    end
  end

  describe "POST /api/v1/draft_tasks" do
    it "creates an unattached drafting draft" do
      api_post "/api/v1/draft_tasks", user: member, company: company,
               params: { draft_task: { title: "Plan", points: 10, note: "see doc" } }

      expect(response).to have_http_status(:created)
      expect(json).to include("state" => "drafting", "points" => 10, "editable" => true, "list_id" => "")
    end
  end

  describe "POST /api/v1/draft_tasks/:id/attach" do
    let(:draft) { create(:draft_task, company: company, author: member, points: 20) }

    it "attaches the draft to the list" do
      allow(DraftTasks::Commands::Attach).to receive(:call).and_return(Result.success(draft))

      api_post "/api/v1/draft_tasks/#{draft.id}/attach", user: member, company: company, params: { list_id: list.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(json["id"]).to eq(draft.id.to_s)
    end

    it "404s for a list the caller cannot see" do
      hidden = create(:list, :private, company: company, owner: admin, member_ids: [admin.id])
      api_post "/api/v1/draft_tasks/#{draft.id}/attach", user: member, company: company, params: { list_id: hidden.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end

    it "forbids non-authors" do
      api_post "/api/v1/draft_tasks/#{draft.id}/attach", user: admin, company: company, params: { list_id: list.id.to_s }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/draft_tasks/:id/detach" do
    it "returns the draft to the unattached pile" do
      draft = create(:draft_task, :ready, company: company, list: list, author: member, attached_at: 1.hour.ago)
      api_post "/api/v1/draft_tasks/#{draft.id}/detach", user: member, company: company
      expect(response).to have_http_status(:ok)
      expect(json).to include("state" => "drafting", "list_id" => "")
    end
  end

  describe "POST /api/v1/draft_tasks/:id/mark_ready" do
    let(:draft) { create(:draft_task, company: company, list: list, author: member, attached_at: 1.hour.ago, points: 20) }

    it "reserves the points" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company
      expect(response).to have_http_status(:ok)
      expect(json).to include("state" => "ready", "reserved_points" => 20)
    end

    it "returns 422 when the draft is not on a list" do
      loose = create(:draft_task, company: company, author: member)
      api_post "/api/v1/draft_tasks/#{loose.id}/mark_ready", user: member, company: company
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 when the budget is short" do
      create(:draft_task, :ready, company: company, list: list, author: member, points: 90)
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE /api/v1/draft_tasks/:id" do
    it "removes the draft" do
      draft = create(:draft_task, company: company, author: member)
      api_delete "/api/v1/draft_tasks/#{draft.id}", user: member, company: company
      expect(response).to have_http_status(:no_content)
      expect(DraftTask.where(id: draft.id)).not_to exist
    end
  end
end
