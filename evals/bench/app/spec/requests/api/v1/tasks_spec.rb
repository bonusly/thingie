require "rails_helper"

RSpec.describe "Tasks API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }

  describe "GET /api/v1/tasks" do
    it "lists visible tasks with a total header" do
      create_list(:task, 3, company: company, list: list, author: admin)
      api_get "/api/v1/tasks", user: member, company: company, params: { per_page: 2 }

      expect(response).to have_http_status(:ok)
      expect(json.size).to eq(2)
      expect(response.headers["X-Total-Count"]).to eq("3")
    end

    it "rejects requests without a key" do
      get "/api/v1/tasks"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/tasks" do
    it "creates a task on a list the user belongs to" do
      api_post "/api/v1/tasks", user: member, company: company, params: { list_id: list.id.to_s, task: { title: "Write docs", points: 5 } }

      expect(response).to have_http_status(:created)
      expect(json["title"]).to eq("Write docs")
      expect(Task.count).to eq(1)
    end

    it "returns 422 when the points exceed the budget" do
      member_membership.update!(points_budget_override: 2)
      api_post "/api/v1/tasks", user: member, company: company, params: { list_id: list.id.to_s, task: { title: "x", points: 5 } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_error["message"]).to match(/points/)
    end
  end

  describe "POST /api/v1/tasks/:id/complete" do
    it "completes an assigned task" do
      task = create(:task, company: company, list: list, author: admin, assignee_ids: [member.id])
      api_post "/api/v1/tasks/#{task.id}/complete", user: member, company: company
      expect(response).to have_http_status(:ok)
      expect(json["state"]).to eq("done")
    end

    it "forbids users who are neither author nor assignee" do
      task = create(:task, company: company, list: list, author: admin)
      api_post "/api/v1/tasks/#{task.id}/complete", user: member, company: company
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "returns 404 for tasks in other companies" do
    api_get "/api/v1/tasks/#{create(:task).id}", user: member, company: company
    expect(response).to have_http_status(:not_found)
  end
end
