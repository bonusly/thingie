require "rails_helper"

RSpec.describe "Admin companies" do
  include_context "with a company and members"

  let(:staff) { create(:user, :staff) }
  let(:staff_company) { create(:company) }

  before { create(:membership, company: staff_company, user: staff) }

  it "forbids non-staff" do
    api_get "/admin/companies", user: admin, company: company
    expect(response).to have_http_status(:forbidden)
  end

  it "lists and filters companies" do
    create(:company, :suspended, name: "Dormant")
    api_get "/admin/companies", user: staff, company: staff_company, params: { suspended: "true" }
    expect(json.map { |c| c["name"] }).to eq(["Dormant"])
  end

  it "shows stats" do
    api_get "/admin/companies/#{company.id}", user: staff, company: staff_company
    expect(json["stats"]).to include("members" => 2, "admins" => 1)
  end

  it "suspends and unsuspends" do
    api_post "/admin/companies/#{company.id}/suspend", user: staff, company: staff_company, params: { reason: "billing" }
    expect(json["active"]).to be(false)

    api_post "/admin/companies/#{company.id}/unsuspend", user: staff, company: staff_company
    expect(json["active"]).to be(true)
  end
end
