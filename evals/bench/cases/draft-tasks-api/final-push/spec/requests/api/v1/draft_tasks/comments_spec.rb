require "rails_helper"

RSpec.describe "Draft task comments API" do
  include_context "with a list and a ready draft"

  before { enable_feature(:draft_tasks) }

  it "lists the comments on the sent task with the originating draft" do
    task = Lists::Commands::ConvertDraftTaskComment.call(draft: draft, actor: admin).value[:task]
    create(:comment, company: company, commentable: task, author: admin, body: "looks good")

    api_get "/api/v1/draft_tasks/#{draft.id}/comments", user: member, company: company

    expect(response).to have_http_status(:ok)
    expect(json.map { |c| c["body"] }).to eq(["ship it", "looks good"])
    expect(json.first["draft"]).to include("id" => draft.id.to_s, "title" => draft.title)
    expect(json.last["draft"]).to be_nil
  end

  it "is empty before the draft is sent" do
    api_get "/api/v1/draft_tasks/#{draft.id}/comments", user: member, company: company
    expect(json).to eq([])
  end

  it "hides private drafts from other list members" do
    draft.update!(visibility: "private")
    api_get "/api/v1/draft_tasks/#{draft.id}/comments", user: create(:user), company: company
    expect(response).to have_http_status(:forbidden)
  end
end
