require "rails_helper"

RSpec.describe "Draft tasks API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  before { enable_feature(:draft_tasks) }

  describe "GET /api/v1/draft_tasks" do
    it "lists the caller's drafts, filtered by state" do
      create(:draft_task, company: company, list: list, author: member)
      ready = create(:draft_task, :ready, company: company, list: list, author: member)
      create(:draft_task, company: company, list: list, author: admin)

      api_get "/api/v1/draft_tasks", user: member, company: company, params: { state: "ready" }

      expect(json.map { |d| d["id"] }).to eq([ready.id.to_s])
    end

    it "is forbidden when the feature is off for the company" do
      enable_feature(:draft_tasks, companies: ["someone-else"])
      api_get "/api/v1/draft_tasks", user: member, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/draft_tasks" do
    it "creates a drafting draft" do
      api_post "/api/v1/draft_tasks", user: member, company: company,
               params: { list_id: list.id.to_s, draft_task: { title: "Plan", points: 10, note: "see doc" } }

      expect(response).to have_http_status(:created)
      expect(json).to include("state" => "drafting", "points" => 10, "editable" => true, "revision" => 1)
    end

    it "rejects read-only keys instead of dropping them" do
      api_post "/api/v1/draft_tasks", user: member, company: company,
               params: { list_id: list.id.to_s, draft_task: { title: "Plan", state: "ready" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_error["message"]).to match(/state/)
    end
  end

  describe "PATCH /api/v1/draft_tasks/:id" do
    it "updates an editable draft and bumps the revision" do
      draft = create(:draft_task, company: company, list: list, author: member)
      api_patch "/api/v1/draft_tasks/#{draft.id}", user: member, company: company, params: { draft_task: { title: "New" } }
      expect(json).to include("title" => "New", "revision" => 2, "last_edited_by_id" => member.id.to_s)
    end
  end

  describe "POST /api/v1/draft_tasks/:id/mark_ready" do
    let(:draft) { create(:draft_task, company: company, list: list, author: member, points: 20) }

    it "reserves the points and takes a final schedule" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company,
               params: { draft_task: { scheduled_for: 1.hour.from_now.iso8601 } }
      expect(response).to have_http_status(:ok)
      expect(json).to include("state" => "ready", "reserved_points" => 20)
      expect(json["points_reserved_at"]).to be_present
    end

    it "rejects read-only keys on the transition" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: member, company: company,
               params: { draft_task: { author_id: admin.id.to_s } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(draft.reload.author_id).to eq(member.id)
    end

    it "forbids non-authors" do
      api_post "/api/v1/draft_tasks/#{draft.id}/mark_ready", user: admin, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/draft_tasks/:id/release" do
    it "returns a ready draft to drafting" do
      draft = create(:draft_task, :ready, company: company, list: list, author: member)
      api_post "/api/v1/draft_tasks/#{draft.id}/release", user: admin, company: company
      expect(json).to include("state" => "drafting", "points_reserved_at" => nil)
    end

    it "rejects state in the body" do
      draft = create(:draft_task, :ready, company: company, list: list, author: member)
      api_post "/api/v1/draft_tasks/#{draft.id}/release", user: member, company: company,
               params: { draft_task: { state: "sent" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(draft.reload).to be_ready
    end
  end

  describe "POST /api/v1/draft_tasks/:id/send_now" do
    it "creates the task and returns it" do
      draft = create(:draft_task, :ready, company: company, list: list, author: member, points: 5)
      api_post "/api/v1/draft_tasks/#{draft.id}/send_now", user: member, company: company
      expect(response).to have_http_status(:created)
      expect(json["title"]).to eq(draft.title)
      expect(draft.reload).to be_sent
    end
  end

  describe "DELETE /api/v1/draft_tasks/:id" do
    it "removes the draft and its recording" do
      draft = create(:draft_task, :with_recording, company: company, list: list, author: member)
      api_delete "/api/v1/draft_tasks/#{draft.id}", user: member, company: company
      expect(response).to have_http_status(:no_content)
      expect(DraftTask.where(id: draft.id)).not_to exist
      expect(Attachment.where(draft_task_id: draft.id)).not_to exist
    end
  end

  it "returns 404 for drafts in other companies" do
    api_get "/api/v1/draft_tasks/#{create(:draft_task).id}", user: member, company: company
    expect(response).to have_http_status(:not_found)
  end
end
