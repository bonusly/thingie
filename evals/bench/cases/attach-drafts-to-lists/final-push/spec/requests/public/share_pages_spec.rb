require "rails_helper"

RSpec.describe "Share pages" do
  include_context "with a list and a ready draft"

  it "renders the list without authentication and counts the view" do
    create(:task, company: company, list: list, author: admin, title: "Public task")
    link = create(:share_link, company: company, list: list, created_by: admin)

    get "/s/#{link.token}"

    expect(response).to have_http_status(:ok)
    expect(json["name"]).to eq(list.name)
    expect(json["tasks"].map { |t| t["title"] }).to eq(["Public task"])
    expect(json["tasks"].first["author_name"]).to eq(admin.display_name)
    expect(json["drafts"]).to eq([])
    expect(link.reload.view_count).to eq(1)
  end

  it "includes attached drafts with the author named" do
    draft
    link = create(:share_link, :with_drafts, company: company, list: list, created_by: admin)

    get "/s/#{link.token}"

    expect(json["drafts"].size).to eq(1)
    expect(json["drafts"].first).to include("title" => draft.title, "state" => "ready", "has_note" => true)
    expect(json["drafts"].first["author"]).to eq("name" => member.display_name)
    expect(json["drafts"].first["attached_at"]).to be_present
  end

  it "hides the author entirely when the draft is private" do
    draft.update!(visibility: "private")
    link = create(:share_link, :with_drafts, company: company, list: list, created_by: admin)

    get "/s/#{link.token}"

    expect(json["drafts"].size).to eq(1)
    expect(json["drafts"].first["author_name"]).to be_nil
    expect(json["drafts"].first["author"]).to be_nil
    expect(response.body).not_to include(member.name)
  end

  it "404s for dead links" do
    get "/s/#{create(:share_link, :revoked, company: company, list: list, created_by: admin).token}"
    expect(response).to have_http_status(:not_found)
  end
end
