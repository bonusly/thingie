require "rails_helper"

RSpec.describe "Points API" do
  include_context "with a company and members"

  describe "GET /api/v1/points" do
    it "returns the weekly balance" do
      create(:draft_task, :ready, company: company, author: member, points: 25)
      create(:points_ledger_entry, company: company, user: member, amount: 15)

      api_get "/api/v1/points", user: member, company: company

      expect(json).to include("budget" => 100, "spent" => 15, "reserved" => 25, "remaining" => 60, "percent_remaining" => 60)
    end
  end

  describe "GET /api/v1/points/ledger" do
    it "returns recent entries with signed amounts" do
      create(:points_ledger_entry, company: company, user: member, amount: 15)
      create(:points_ledger_entry, :refund, company: company, user: member, amount: 5)

      api_get "/api/v1/points/ledger", user: member, company: company

      expect(json.map { |e| e["signed_amount"] }).to contain_exactly(-15, 5)
    end

    it "marks entries that settled a draft" do
      draft = create(:draft_task, :sent, company: company, author: member, points: 15)
      create(:points_ledger_entry, :escrow, company: company, user: member, amount: 15, draft_task_id: draft.id)

      api_get "/api/v1/points/ledger", user: member, company: company

      expect(json.first).to include("from_draft" => true, "draft_task_id" => draft.id.to_s)
    end
  end
end
