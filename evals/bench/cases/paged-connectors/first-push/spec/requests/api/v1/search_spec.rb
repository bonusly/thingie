require "rails_helper"

RSpec.describe "Connected search API" do
  include_context "with a github connector account"

  def issue(id, title: "Issue #{id}")
    { "id" => id, "title" => title, "html_url" => "https://github.com/acme/app/issues/#{id}", "updated_at" => "2026-10-15T10:00:00Z", "number" => id, "state" => "open" }
  end

  describe "GET /api/v1/search/connected" do
    it "returns matching items with a cursor to continue from" do
      allow(client).to receive(:issues).with(hash_including(cursor: "2")).and_return(Connectors::Page.new(items: [issue(1, title: "Flaky build")], next_cursor: 3))

      api_get "/api/v1/search/connected", user: member, company: company,
                                          params: { q: "flaky", providers: ["github"], cursor: "2", since_days: "3" }

      expect(response).to have_http_status(:ok)
      expect(json["items"].map { |i| i["external_id"] }).to eq(["1"])
      expect(json["items"].first["provider"]).to eq("github")
      expect(json["next_cursor"]).to eq("3")
      expect(json["truncated"]).to be(true)
      expect(client).to have_received(:issues).with(hash_including(since: a_value_within(5.seconds).of(3.days.ago)))
    end

    it "skips providers the user has not connected" do
      allow(client).to receive(:issues).and_return(Connectors::Page.empty)

      api_get "/api/v1/search/connected", user: member, company: company

      expect(json["items"]).to eq([])
      expect(json["skipped"]).to contain_exactly("slack", "linear")
    end

    it "rejects an unknown provider" do
      api_get "/api/v1/search/connected", user: member, company: company, params: { providers: ["jira"] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_error["message"]).to include("jira")
    end

    it "requires authentication" do
      get "/api/v1/search/connected"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
